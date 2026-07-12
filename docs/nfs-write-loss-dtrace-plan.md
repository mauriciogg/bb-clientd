# DTrace plan: pinpointing the macOS NFS client write drop

Companion to `nfs-vs-fskit-latency-findings.md` §15 and the bb-remote-execution
commit "fsmount: grow NFSv4 socket buffers to stop silent macOS client write
loss". Those establish **what** happens; this documents the prepared-but-not-yet-run
plan to find **where in the kernel** it happens.

## What we know (recap)

The macOS NFS client (Darwin 25.5, NFSv4.1 over an AF_LOCAL socket) silently
loses ~32 KiB chunks from its async writeback under socket backpressure
(8 KiB `net.local.stream.*space` buffers vs ~33 KiB WRITE records at
`--jobs=300`). Measured at both ends in a single run:

- Client ktrace (`debug_ctl=0x111C`, DKIO io_start/io_end pairing): every WRITE
  RPC the client issued completed successfully (0 unmatched, all errno=0).
- Server probes: the lost byte range never arrived (opWrite == VirtualWrite
  exactly; all rejection/replay/sequence counters zero; single healthy
  connection; ONC-RPC framing never desynced).

Conclusion: **the WRITE RPC for the lost range is never created.** The drop is
in the client's dirty-data bookkeeping (nfsbuf dirty ranges / UBC page state),
upstream of RPC issuance. The corrupted range is always the *leading* part of a
32 KiB client block whose tail was delivered later — i.e. the dirty-range
accounting advanced past data that was never transmitted.

ktrace hit its ceiling here: the kext's tracepoints expose only the four args
Apple chose to log, carry no file identity (buffer/vnode pointers are reused
under 300-way concurrency), and cannot capture stacks or evaluate predicates.
Synthetic repros (concurrent writers, a byte-faithful Java mimic of Bazel's
CompressedFileWriteAction, and a 1000-target `ctx.actions.write` + remote
validation Bazel suite under `memory_pressure`) have NOT reproduced the loss;
only real android builds have. So the capture must run against the real build,
and needs in-kernel filtering — which is exactly what DTrace fbt provides.

## Prerequisites

1. SIP with DTrace restrictions disabled. From Recovery: `csrutil enable
   --without dtrace` (narrower and safer than full `csrutil disable`).
   CAUTION: on this machine the first attempt caused a black screen after
   login (suspected interaction with the endpoint-security stack racing
   early-boot exec holds); revert from Recovery with `csrutil enable` if that
   happens.
2. Verify before trusting anything:

   ```sh
   csrutil status                                  # must list DTrace restrictions: disabled
   sudo dtrace -l -m com.apple.filesystems.nfs | wc -l   # >0: kext fbt probes visible
   sudo dtrace -l \
     -n 'fbt::nfs_buf_write_finish:entry' \
     -n 'fbt::nfs_buf_release:entry' \
     -n 'fbt::nfs_vinvalbuf2:entry'                # all three must resolve
   ```

   If a function is missing it was inlined/blacklisted; re-target its callers.

## Strategy: enforce the accounting invariant in-kernel

Rather than logging everything, the script (`tools/nfs_drop_hunt.d`) screams
only on invariant violations and keeps a compact ledger for the rest:

| tag     | probe                                                        | catches |
|---------|--------------------------------------------------------------|---------|
| `DROP!` | `nfs_buf_release:entry` where the buffer has `NB_INVAL` set while dirty bytes/pages remain (write buffers only) | dirty data being discarded un-written — the money shot, with `stack()` naming the guilty path |
| `VINV`  | `nfs_vinvalbuf2` / `nfs_vinvalbuf_internal` called without `V_SAVE` | discard-without-flush requests, with stack |
| `DUMP!` | `ubc_upl_abort(_range)` with `UPL_ABORT_DUMP_PAGES` (kernel proper — works even if kext probes are blacklisted) | VM-level destruction of page contents; stack shows if NFS is the caller |
| `RPC`   | `nfs_buf_write_rpc:entry`                                    | issuance ledger: np, block, dirty range of every WRITE RPC |
| `FIN`   | `nfs_buf_write_finish:entry`                                 | completion accounting: offio/endio (what it thinks it wrote) vs dirtyoff/dirtyend/dirty-bitmap (what remained) |
| `PGINV` | `nfs_buf_page_inval_internal:entry`                          | VM consulting a buffer for invalidation |
| `CAL`   | first 5 write RPCs                                           | offset sanity: `bufsize` must print 32768, else struct offsets are wrong and ALL output is garbage |

Key suspects these cover, from reading the kext source
(apple-oss-distributions/NFS, `nfs_bio.c` / `nfs_vnops.c`):

- `nfs_buf_write_finish` clears dirty page bits for `nb_offio..nb_endio` and
  wipes `nb_dirtyoff/nb_dirtyend` — correct only if that range truly reached
  the wire.
- `nfs_vinvalbuf*` without `V_SAVE` discards dirty buffers by design.
- `nfs_vnop_pageout`'s abort branches (`UPL_ABORT_DUMP_PAGES`) destroy page
  contents on error paths.
- Buffer reuse/steal under pressure (`nfs_buf_get`/freeup) reclaiming a
  delayed-write buffer without flushing it.

## struct nfsbuf field access

fbt gives raw `arg0` pointers; the kext ships no CTF types. Offsets are
computed by compiling the struct layout copied from the kext source
(`tools/nfsbuf_offsets.c` — kernel-only types stubbed with their RELEASE-ABI
equivalents) and pasting the emitted `OFF_*` constants into the D script.
Current values (Darwin 25.5, NFS kext source drop of July 2026):

```
nb_lblkno 0x38, nb_dirty 0x90, nb_np 0xd8, nb_flags 0xf8, nb_bufsize 0x100,
nb_error 0x104, nb_dirtyoff 0x120, nb_dirtyend 0x128, nb_offio 0x130,
nb_endio 0x138   (sizeof == 0x148)
```

The `CAL` probe is the runtime tripwire against ABI drift: if it does not
print `bufsize=32768` on real traffic, recompute the offsets before trusting
anything else.

## Run procedure

```sh
# 1. daemon in repro config (the corruption must be reproducible):
sudo sysctl -w net.local.stream.recvspace=8192 net.local.stream.sendspace=8192
BB_NFS_REPRO=1 BB_NFS_SOCKBUF=8192 configs/launch_bb_clientd_engflow_rbe_macos.sh
nfsstat -m | grep "mount flags"        # must NOT contain "sync"

# 2. start the hunt BEFORE the build; leave running:
sudo dtrace -s tools/nfs_drop_hunt.d -o /tmp/nfs_drop_hunt.log
#    check CAL lines immediately: bufsize=32768 or STOP.

# 3. run the real corrupting build (mushroom-gms-release with the bb_clientd
#    output-service flags, --noremote_accept_cached, --jobs=300).

# 4. on the corruption failure:
grep -E "DROP!|VINV|DUMP!" /tmp/nfs_drop_hunt.log
#    hole block number = hole_offset / 32768; ledger check:
grep " lblk=<N> " /tmp/nfs_drop_hunt.log     # RPC/FIN history for that block
```

## Decision tree

- `DROP!`/`VINV`/`DUMP!` fires with an NFS stack near the failure → done: the
  exact function (and via the stack, the exact call path) that discards the
  data. That line goes verbatim into the Apple Feedback report.
- Nothing fires, but the `FIN` ledger shows the corrupt block completing with
  `endio` covering bytes no `RPC` line ever carried → the accounting bug is
  inside `nfs_buf_write_finish`'s clearing logic; iterate with `:return`
  probes diffing the dirty bitmap across the call.
- `CAL` prints garbage → offsets stale; regenerate with `nfsbuf_offsets.c`
  against the current kext source before re-running.

## Notes

- fbt probes on hot functions are cheap when predicates filter in-kernel; the
  ledger printf volume (~100k lines/build) needs `bufsize=256m` (already set
  in the script) — watch dtrace's "dynamic variable drops" warnings.
- The mitigation knobs make flipping configs trivial: production is 4 MiB
  socket buffers (in-code) + 1 MiB sysctls (asserted by the launch script);
  repro is `BB_NFS_REPRO=1 BB_NFS_SOCKBUF=8192` + 8 KiB sysctls set before
  daemon start.
- Kext source clone used for all offsets/line numbers:
  https://github.com/apple-oss-distributions/NFS
