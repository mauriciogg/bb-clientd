# bb_clientd on macOS: NFS vs FSKit virtual-FS latency findings

Investigation into why builds that route Bazel's outputs/inputs through a
bb_clientd virtual mount (`--experimental_remote_output_service` +
`--remote_download_minimal`, EngFlow-backed cache) are dramatically slower on
macOS, and whether the FSKit/BridgeFS transport helps.

**TL;DR**
- A clean C++ build through the NFS mount is **~17× slower per compile action**
  than local (median), and the slowdown is **~100% metadata-syscall latency**
  (`open`/`stat` on headers), not data reads or CPU.
- macOS's NFS-over-unix-socket transport adds an **irreducible ~27 µs/stat,
  ~109 µs/open floor** (a do-nothing NFS server) — ~2.3× / ~3.2× over *cold* local
  (stat / open; see §4 amendment). bb_clientd's
  real backend adds more on top (~161 µs/stat), most of which is server-side work.
- **FSKit/BridgeFS is worse, not better**: full 2-hop ~5.6 ms/stat; even a
  pure single-hop FSKit filesystem (extension answers locally, no gRPC) is
  **~165 µs/stat ≈ 6× the NFS floor**, and that cost is FSKit framework
  overhead that extension-side optimization cannot remove (verified).
- **Conclusion**: for local execution this model is fundamentally handicapped by
  metadata round-trip latency. Realistic paths forward: (a) keep the compiler's
  input tree on local disk (use bb_clientd as a plain cache, not the input FS),
  (b) optimize bb_clientd's Go for the NFS path (server-side stat work is
  optimizable toward the 27 µs floor), and/or (c) accept this only pays off with
  **remote execution**, where the hot metadata loop runs where the FS is local.
- **Remote execution (tested — §8) removes the NFS penalty** entirely: compiles
  run on the linux workers' local FS. It first *looked* slower than local, but
  that was two build-config artifacts, not RBE — the repo's default execution log
  serializes at high `--jobs` (§9a), and `--jobs=HOST_CPUS*2` caps even remote
  actions (§9b). Neutralize both and RBE fans out on the farm; the durable win is
  warm-cache hits, not cold remote execution.

---

## 1. Setup under test

- bb_clientd fronting Snap's EngFlow cache; local-write `read_fallback` blobstore
  (config: `configs/bb_clientd_engflow.jsonnet`). Auth via `sc-lca-1` token file
  (see `docs`/config comments).
- Bazel flags: `--remote_cache=unix://…/bb_clientd/grpc`,
  `--experimental_remote_output_service=…`, `--remote_download_minimal`,
  `--remote_upload_local_results`, `--remote_instance_name=engflow`.
- macOS 15 (Darwin 25.5.0), Apple Silicon, 16 cores. Bazel 8.2.1.
  NFSv4.1 mount over a unix socket; FSKit via the BridgeFS extension.

## 2. Whole-build impact

From Bazel JSON profiles (a full `//src:libclient.so` build), matching **6,485
identical `CppCompile` source files** across an NFS build and a non-NFS build
(controls for action mix), comparing subprocess wall time (`Local execution
process wall time`, i.e. actual execution excluding resource-acquisition queueing):

| NFS / non-NFS per-action ratio | p10 | p50 | p90 | max |
|---|---|---|---|---|
| CppCompile subprocess wall | 1.0× | **17.5×** | 50.7× | 96.7× |

`CppArchive`/`CppLink` were **not** slowed (few large files) — the fingerprint of
metadata/small-file latency, not bandwidth. High time in Bazel's "Acquiring
resources for:" spans was a *symptom* (cores held by I/O-stalled compiles), not
the cause; ResourceManager gated ~16 concurrent (1/core) while ~32 queued.

## 3. Isolated single-compile + syscall attribution

One compile (`src/content_manager/.../FileGroupResolverImpl.cpp`) run by hand from
the execroot, warm (3rd run — warmth made no difference, ruling out lazy CAS
materialization):

| | user | system | CPU | wall |
|---|---|---|---|---|
| non-NFS | 2.88 s | 0.20 s | 99% | 3.09 s |
| NFS | 3.11 s | **2.08 s** | **47%** | 10.97 s (~3.5×) |

Same user (CPU) time; NFS system time 10×, CPU utilization halved → I/O-bound.

`fs_usage -w -f filesys` on the `clang` process (per-syscall latency):

| syscall | count (both) | native mean | NFS mean | ratio | Δtotal |
|---|---|---|---|---|---|
| `open` | 27,017 | 0.005 ms | 0.165 ms | ~31× | +4.30 s |
| `stat64` | 21,528 | 0.004 ms | 0.161 ms | ~40× | +3.38 s |
| `pread` (data) | 1,483 | 0.002 ms | 0.002 ms | 1× | ~0 |

**Identical call counts** (same access pattern); `open`+`stat` account for essentially
**all** of the +7.9 s wall gap. Data reads (`pread`) are unchanged. It's the
C++ include-search metadata storm (thousands of header `open`/`stat` probes),
each an NFS round-trip.

## 4. Transport floor benchmarks

Method: a do-nothing "floor" server (`cmd/nfs_floor`) exposing a `StaticDirectory`
of 20,000 constant `LinkableLeaf` files (VirtualGetAttributes → constants,
VirtualOpenSelf → OK), served over the **same** bb-remote-execution NFSv4 stack
and macOS mount that bb_clientd uses. Same binary run with an fskit config serves
the identical tree over BridgeFS. Client driver: `scripts/bench_stat_open.py`
(and an inline `os.stat` loop) — first-touch over distinct files (defeats the
client attribute cache), single-threaded.

| `stat` | `open`+close | notes |
|---|---|---|
| native (local APFS), **cold** | **11.4 µs** | **33.8 µs** | re-measured after reboot, cold cache (open on 5,000 files) |
| native (local APFS), warm | 1.4 µs | 11.9 µs | original run — files just created, metadata cache-hot (misleadingly low) |
| **NFS floor** (do-nothing server) | **26.7 µs** | **109 µs** | pure NFS transport — ~2.3× cold-native (stat), ~3.2× (open) |
| NFS + real bb_clientd (over NFS) | ~161 µs | ~165 µs | from isolated-compile `fs_usage` |
| **FSKit floor, 2-hop** (kernel↔ext↔gRPC↔server) | **5,646 µs** | 6,041 µs | current BridgeFS architecture |
| **FSKit floor, LOCAL** (kernel↔ext only, no gRPC) | **165 µs** | — | extension answers stat/lookup locally |
| FSKit LOCAL, lock-free lookup | 168 µs | — | removing `itemsLock`+dict = no change |

> **Amendment (native baseline).** The original native `stat` (1.4 µs) was
> cache-hot — the files had just been created, so their metadata sat in the
> kernel cache and no filesystem access occurred. Re-measured **cold after a
> reboot, native `stat` is 11.4 µs/op** (19,999 ops, 0.228 s) — the honest
> cold-local baseline, comparable to the first-touch NFS/FSKit numbers. This
> shrinks the *transport* penalties considerably: the NFS floor is only ~2.3×
> cold-local for stat (not ~19×). Cold native `open` was also re-measured (on
> 5,000 files) at **33.8 µs/op**, so the NFS `open` floor (~109 µs) is only ~3.2×
> cold-local. The large gaps that remain — real bb_clientd/NFS (~161 µs ≈ **14×**
> cold-native stat; ~165 µs open ≈ ~5×) and FSKit (~165 µs ≈ **14×** stat) — are
> server/framework work, not transport.

Reads best→worst: **cold-local (~11–34 µs) ≪ NFS floor (27–109 µs) ≪ real bb_clientd/NFS
(161–165 µs) ≪ FSKit local (165 µs) ≪ FSKit 2-hop (5.6–6.0 ms)**.

### Interpretation
- **NFS transport floor** (~27 µs/stat) is irreducible — even a server doing
  nothing pays the kernel-NFS-client → XDR → socket round-trip. ~2.3× cold-local (stat).
- **bb_clientd's real NFS stat (~161 µs) is mostly its own work** (~83% =
  ~134 µs of node/CAS/path-resolution over the ~27 µs floor). This part **is
  optimizable server-side** (Go). Per-op server histogram was added to measure
  exactly which op (LOOKUP vs GETATTR) — see §6.
- **FSKit is structurally worse.** The 2-hop architecture (kernel→BridgeFS
  Swift→gRPC→bb_clientd, plus per-op logging + OTLP tracing) is ~5.6 ms/stat.
  Removing the second hop entirely (extension returns constants locally) still
  costs **~165 µs/stat = ~6× the NFS floor** — that residual is FSKit
  **framework** kernel↔extension IPC, and removing an in-extension lock + hash-map
  insert changed nothing (165→168 µs). So it is **not** optimizable on the
  extension side, and FSKit cannot match the NFS kernel client here.

## 5. Strategy conclusions

- **FSKit/BridgeFS is not a viable transport** for this metadata-heavy workload:
  even best-case single-hop is 6× the NFS client, and unoptimizable.
- **NFS + optimize the Go** is the lever with real headroom, and the corrected
  baseline makes it *more* attractive than first thought: bb_clientd's ~161 µs/stat
  is ~14× cold-native, but ~83% of it is server work over a ~27 µs NFS transport
  floor that is itself only **~2.3× cold-local**. So driving the Go stat path
  toward the floor could turn a ~14× penalty into ~2–3×, which may be tolerable.
- The remaining drag is **`open`**: the NFS transport floor for `open` is ~109 µs
  (NFSv4 `OPEN` is a stateful, heavier op) — ~3.2× cold-local, *not* server work
  and won't optimize away. Smaller than the stat penalty, but it caps how close
  local builds can get.
- Net: **NFS + Go optimization is worth pursuing** for local builds (measure the
  server-side split with the histogram first — §6 — to confirm the stat headroom),
  but the metadata-heavy compile loop still fits **remote execution** best (FS is
  local on the workers; the mount is for lazy output access, not include search).
  Keeping compiler inputs on local disk and using bb_clientd purely as a cache is
  the other clean option.

## 6. Artifacts produced

In `bb-clientd`:
- `cmd/nfs_floor/{main.go,BUILD.bazel}` — do-nothing floor server (constant-file
  `StaticDirectory`; works over NFSv4 or fskit depending on config).
- `configs/bb_clientd_floor.jsonnet` (NFS), `configs/bb_clientd_floor_fskit.jsonnet`
  (fskit, automounts BridgeFS, `source: /localhost:9999`).
- `scripts/bench_stat_open.py` — first-touch stat/open latency over `f%06d` files.
- `scripts/fs_usage_attrib.py` — per-syscall latency from an `fs_usage -w -f filesys`
  capture (filter by process); pass two traces for a side-by-side ratio.
- `scripts/nfs_op_latency.py` — splits bb_clientd server-side per-op latency
  (from the histogram below) vs client-side latency (fs_usage) → server vs
  transport attribution. **Not yet run against a real instrumented compile.**

In `bb-remote-execution` (used via `--override_module`):
- `pkg/filesystem/virtual/nfsv4/metrics_program.go` — new histogram
  `buildbarn_nfsv4_program_compound_operation_duration_seconds{operation=…}`.
- `nfs40_program.go` / `nfs41_program.go` — per-op timing in the compound dispatch
  loops (nfs41 is the live path; both instrumented). Diagnostics HTTP server
  enabled in the engflow config (`127.0.0.1:12345`) for pprof + metrics.

## 7. Open items / caveats

- **TEMPORARY HACK, needs revert:** `virtualfs/InMemoryFS/Sources/BridgeFSCore/
  BridgeVolume.swift` — `attributes()` and `lookupItem()` were short-circuited to
  return local constants (no gRPC/logging/tracing) for the pure-FSKit measurement.
  The installed BridgeFS is currently a non-forwarding "constant FS." Revert both
  functions and rebuild/reinstall (`scripts/10-build.sh` + `20-install-and-enable.sh`)
  to restore real BridgeFS.
- Floor mounts/servers (`~/Snapchat/Dev/nfs_floor`, `~/Snapchat/Dev/nfs_floor_fskit`,
  fsmount server on `:9999`) may be left mounted/running — tear down with
  `umount -f` + killing `nfs_floor`.
- Numbers mix measurement tools (Python `os.stat` loop for floors; `fs_usage` on
  `clang` for real bb_clientd). Same order of magnitude and both ~single-threaded,
  but treat the splits as approximate, not µs-exact.
- The 2-hop→local FSKit delta (5,646→165 µs) also removed per-op logging + OTLP
  tracing, so it conflates the gRPC hop with that logging/tracing; the clean
  pure-FSKit floor (165 µs) is the solid number.
- The server-side histogram (§6) would attribute bb_clientd's ~134 µs NFS stat
  overhead to specific ops (LOOKUP vs GETATTR) — run the isolated compile against
  the instrumented bb_clientd, snapshot `/metrics` before/after, and feed
  `nfs_op_latency.py`.

## 8. Remote-execution experiment (the actual fix)

bb_clientd fronting Snap's EngFlow **remote execution** (not just cache):
`configs/bb_clientd_engflow_rbe.jsonnet` (+ `configs/launch_bb_clientd_engflow_rbe_macos.sh`).
Imports the engflow config and overrides: cluster → the RBE endpoint
`engflow-cache-rbe-gcp-prod.sc-corp.net` (serves CAS+AC+Execution),
`uploadResultsToRemote:: true` (write-through CAS — RBE workers must read Bazel's
uploaded inputs from EngFlow's CAS), and a `schedulers` entry so `Execute` is
proxied to EngFlow. bb_clientd registers an ExecutionServer
(`NewDemultiplexingBuildQueueFromConfiguration`), so `--remote_executor=unix://…`
routes Execute through it. Bazel side: `--config=rbe_engflow_macos_arm64`
(host=mac, exec=linux workers) with `--remote_executor`/`--remote_cache` pointed
at bb_clientd's socket (no `--remote_instance_name`).

Three fixes were required to get it working:
1. **Empty instance-name prefix.** Keying the cluster on `engflow-rbe` made
   bb_clientd forward that instance name to EngFlow, which rejects it. Keyed the
   cluster on `''` so an empty instance name matches and forwards through as
   empty (what EngFlow RBE expects); no `--remote_instance_name` needed.
2. **TLS `serverName` (SNI).** EngFlow RBE rejected bb_clientd's `tls: {}` with
   `tls: illegal parameter`. Per EngFlow's bb_clientd docs, the gRPC client needs
   `tls: { serverName: <host> }`. Snap's EngFlow uses **LCA token** auth (the
   `sc-lca-1` header we already inject), *not* the static mTLS client certs the
   generic EngFlow docs assume — so `serverName` alone fixed the handshake.
3. **Disable BES + BEP file upload:** `--bes_backend= --bes_results_url=
   --remote_build_event_upload=minimal` (avoids build-event auth + uploading the
   local profile/exec-log to the CAS).

**Result:** RBE removes the NFS penalty — the profile shows **0 `local action
execution` spans**; all compiles run remotely (the include-search metadata storm
happens on the workers' local FS, not the mac's mount). Per-action phase medians
(from the profile, after §9 fixes):

| phase (per remote action) | p50 | p90 |
|---|---|---|
| total remote action | 2,793 ms | 9,470 ms |
| actual exec (worker) | 1,552 ms | 4,901 ms |
| queuing (scheduler) | 1,217 ms | 10,893 ms |
| upload inputs / setup / fetch | ~0.37 / 0.37 / 0.29 s | |

Achieved concurrency ~33 actions in-flight (max 190), ~16 actually executing.
Cold-build RBE overhead (queue + input upload + setup/fetch ≈ 45% of each action)
means a *cold single-machine* build still doesn't beat local — the durable RBE
win is **warm-cache hits** (skip execution entirely), which this cold run doesn't
show. bb_clientd also adds a proxy hop on the write-through upload path; a
direct-RBE A/B (no bb_clientd) would isolate that.

## 9. Benchmark-skewing gotchas (found the hard way)

These dominated early numbers and must be neutralized for honest measurements:

**9a. The execution log serializes at high `--jobs`.** The repo enables it for
*every* build: `.bazelrc:204 build --config=execution_log` →
`--execution_log_compact_file=…/bzl/logs/bazel_execution.log`. It's written
through a single lock — `CompactSpawnLogContext.logEntrySynchronized` /
`logEntryWithoutIdSynchronized` (`synchronized` methods on the one context
instance, guarding the shared `entryMap` dedup map) in
`bazel/src/main/java/com/google/devtools/build/lib/exec/CompactSpawnLogContext.java`.
Each spawn logs all its input/output nodes through that lock. At `--jobs=200`
(RBE) with C++'s huge input trees, ~318 threads park in `logEntry/synchronized`
simultaneously, **p50 5.4 s / p90 20 s per span** — dwarfing the actual work and
making RBE look far slower than it is. Invisible at ~16 jobs (local), pathological
at 200. **Fix: `--execution_log_compact_file=`** (empty) to disable it. Profiler
category is `SPAWN_LOG` (shows as "logging spawn"; span names `logSpawn`,
`logEntry`, `logEntry/synchronized`, `logEntryWithoutId`).

**9b. `--jobs` caps remote actions too.** `.bazelrc:181 build --jobs=HOST_CPUS*2`
bounds the scheduler's total in-flight actions — local **and** remote — so on a
16-core mac RBE is capped at ~32 concurrent regardless of farm capacity.
`--jobs` is global concurrency, not a local-only limit (the adjacent
`#--local_resources=cpu=HOST_CPUS` is commented out and would only gate local
anyway). The RBE config raises it (`.bazelrc.rbe:17 build:rbe_engflow --jobs=200`);
verify with `--announce_rc`, and pass an explicit high `--jobs` on the command
line to be sure.

## 10. Additional artifacts (RBE + benchmark)

- `configs/bb_clientd_engflow_rbe.jsonnet`, `configs/launch_bb_clientd_engflow_rbe_macos.sh`
  — bb_clientd fronting EngFlow RBE (write-through CAS + schedulers).
- `serverName` added to the shared `grpcClient` in `configs/bb_clientd_engflow.jsonnet`
  (TLS SNI; benign for the cache path, required for the RBE endpoint).
- **Cache-invalidation target for repeat benchmarks:** edit
  `src/utils/src/utils/concurrency/SerialTaskQueue.hpp` (bump the `benchmark-nonce`
  comment). It's the highest-fanout header physically in `src/utils` (~203 `#include`rs),
  chosen via dep-graph in-degree (`//src/utils:utils` = 112 dependents, the most)
  + include-frequency. `git checkout` it to restore a clean tree.
- Full RBE build command (note the §9 flags):
  `bzl build //src:libclient.so --config=rbe_engflow_macos_arm64 --execution_log_compact_file= --bes_backend= --bes_results_url= --remote_build_event_upload=minimal --jobs=<high> --remote_executor=unix://…/bb_clientd/grpc --remote_cache=unix://…/bb_clientd/grpc --remote_download_minimal --experimental_remote_output_service=unix://…/bb_clientd/grpc --experimental_remote_output_service_output_path_prefix=…/bb_clientd/outputs --noremote_cache_compression`

## 11. CAS output service on BridgeFS (FSKit passthrough) — RBE build attempt

Goal: replace bb_clientd's NFS output tree with the `virtualfs/InMemoryFS`
**BridgeFS passthrough** FSKit mount + the separate **`bb-output-service`** daemon
(REv2 output service; stages RBE-produced blobs as hardlinks into a shared backing
dir). Config: `configs/cas-config.engflow-rbe.jsonc` + launcher
`scripts/40-run-output-service-engflow-rbe.sh` (mints `sc-lca-1`, address
`grpcs://engflow-cache-rbe-gcp-prod.sc-corp.net:443`). Build uses the §9/§10 flags
with `--experimental_remote_output_service=unix:<bb_out.sock>` and
`--experimental_remote_output_service_output_path_prefix=<mount>`.

### Passthrough FS bugs found + fixed (all confirmed via probes)
The Apple PassthroughFS sample was never exercised against a Bazel `bazel-out`.
Hosting one surfaced five real correctness bugs (all in
`InMemoryFS/Sources/BridgeFSCore/`):
1. `createSymbolicLink` inverted directory guard (`!=`/`&&` → `==`/`||`) — ENOTDIR
   on every symlink create.
2. `createSymbolicLink` inverted `setAttributes` callback (`error != nil` → `== nil`).
3. `openWithMode` OR'd `O_SYMLINK` for **every** item type → dirs/files got fds that
   `mkdirat`/`fstat` rejected (ENOTDIR/EBADF). Fixed: `O_DIRECTORY` for dirs,
   `O_SYMLINK` only for symlinks, plain for files.
4. **EBADF on symlink stat (read path):** `getAttributes` did `fstat`/`fgetattrlist`
   on the item's own fd; a symlink's `O_SYMLINK` fd rejects both with EBADF. Crashed
   Bazel's `checkOutputs` lstat of `_virtual_includes` trees. Fixed: stat
   path-relative from the parent (`fstatat`/`getattrlistat` + `AT_SYMLINK_NOFOLLOW`/
   `FSOPT_NOFOLLOW`); root falls back to its own dir fd.
5. **EBADF on symlink create (write path):** `PassthroughFSItem.initInode()` opened
   the new symlink `O_SYMLINK` then `fstat`'d it → EBADF, failing `createSymbolicLink`.
   Same fix (fstatat from parent).

With these + `_tmp` pre-created (see below), the build reached **real remote
execution: 6394 processes, remote cache hits, 300-way concurrency**, staging outputs
through the mount.

### Remaining blocker — FSKit stale-cache on out-of-band writes (architectural)
`bb-output-service` writes the output tree (dirs + CAS hardlinks) **directly to the
shared backing dir, out-of-band from the FSKit mount**. FSKit (kernel VFS) caches
attributes and **negative name lookups**; there is no push-invalidation, and — by the
design's "no RPC between daemon and extension" rule — the daemon has no channel to
invalidate the extension's cache even if one existed. Result: Bazel intermittently
sees freshly-staged outputs as missing:
- Fresh build: `mkdir bazel-out/_tmp/actions` → ENOENT (mount's negative-lookup of the
  daemon-created `<output_base>/` is stale). Pre-creating `_tmp/actions` through the
  mount unblocks this instance.
- During staging: `output '…/_objs/…/dummy.pic.o' was not created`,
  `runfiles/MANIFEST is a dangling symbolic link`. **Verified:** the files exist on
  both the backing AND the mount immediately after — Bazel's `checkOutputs` lstat
  simply raced a stale FSKit view. `mkdir -p`/`ls` from a shell always work (cache
  settles by then).

This is the documented caveat (`docs/CAS-OUTPUT-SERVICE.md`: "no RPC… FSKit has no
push cache-invalidation… out-of-band edits to already-looked-up paths can read
stale"). It is **not** a discrete Swift bug — the passthrough+separate-daemon model is
fundamentally incompatible with reading outputs immediately after the daemon stages
them, unless either (A) the mount disables attribute/negative caching entirely (no
FSKit knob found for this; kernel-driven), or (B) the FS extension itself is the
output-service backend over gRPC (BridgeVolume mode — single source of truth, no
out-of-band writes, cache-consistent — but the "two hops" latency this benchmark set
out to avoid).

**Recommendation:** for the actual RBE benchmark use the validated bb_clientd path
(§10). The BridgeFS passthrough CAS output service needs the caching/architecture
issue resolved (option B) before it can host a full build reliably.

## 12. Alternative: Bazel `--output_base` inside the CAS mount (no output service)

Idea (drops §11's output service): point `bzl --output_base` at a dir inside the
BridgeFS passthrough mount and build normally. The passthrough content-addresses
every file it writes into `cas/` on close, so outputs dedup for free — and, crucially,
**Bazel is the only writer through the mount**, so there are no out-of-band daemon
writes and none of §11's FSKit stale-cache wall.

Bazel's server *does* start with its socket in the mount (the socket concern was moot).
But hosting a real workload surfaced more passthrough FS gaps; fixed in order:

6. **No extended-attribute support.** `PassthroughFSVolume` didn't conform to
   `FSVolume.XattrOperations` (the Apple sample port dropped it). macOS therefore
   synthesized AppleDouble `._name` sidecars for every file's xattrs
   (provenance/quarantine/etc.), and ops on those returned ENODATA — breaking `git`,
   `rm -rf`, everything. Implemented get/set/list xattr backed by
   f{get,set,list,remove}xattr on the item fd (`PassthroughFSVolumeXattr.swift`).
   Result: `._` files gone, native xattrs work.
7. **`renameItem` never opened the dir fds.** It called
   `renameatx_np(fromDir.fileDescriptor, …, toDir.fileDescriptor, …)` but directory
   items are closed after use (fd == -1), unlike `createItem` which guards with
   `upgradeOpenMode`. So `git`'s `config.lock` → `config` rename failed ENOENT
   *flakily* (worked iff the dir fd happened to still be cached open). Added the same
   open/close guard.
8. **Inode-keyed item cache collides under CAS dedup.** `lookupItem` does
   `itemCache[inode]`, but content-addressing hardlinks identical-content files to one
   blob, so distinct paths share an inode (e.g. every fresh `.git/config` → link count
   grows). The cache returned the *wrong* item (wrong name/parent) for any
   duplicate-content file, and a downstream path returned `POSIXError` from a stale
   global `errno` (ENODATA/96). Added a name+parent check on cache hit.

### Conclusion: passthrough is too fragile for a real workload (for now)
Even after 6–8, `git init` in the mount still fails — and the failure **flip-flops
run-to-run between ENOENT and ENODATA** on the same step. That non-determinism is the
finding: the passthrough's item/fd/inode model is racy and inode-collision-prone,
made worse by (a) CAS-on-close mutating inodes out from under cached items, (b) per-op
open/close of directory fds that other cached items still reference, and (c)
concurrent FSKit worker threads. Each point fix moves the symptom rather than removing
it. Making this a reliable general-purpose FS needs a cache/fd-lifecycle redesign
(key items by a stable identity, not the backing inode; stop churning dir fds), not
more spot fixes.

**Net:** the approach is architecturally sound (no stale-cache wall), and the mount is
now far more capable (xattrs, symlink trees, rename), but it is not yet trustworthy as
a Bazel output base. Use the validated bb_clientd path (§10) for the benchmark.

## 13. Item-cache redesign (goal A) — SUCCESS; new blocker is repo-fetch immutability

Re-keyed the item cache from the backing inode to a stable **(parent inode, name)**
identity (`ItemKey`), updating every cache site (lookup/create/createSymlink/rename/
remove/reclaim), plus fixed `createSymbolicLink`'s missing dir-open. Directories are
never content-addressed, so a parent's inode is a unique, stable key.

**Result: the flakiness is gone.** `git init` + `config` + `add` + `commit` now
succeed deterministically, and a **15× fresh-repo stress loop (init+commit+rev-parse)
passed 15/15** — where before it flip-flopped ENOENT/ENODATA. The inode-keyed cache
colliding under CAS dedup was the real defect; the fd-churn concern (goal B) turned
out not to be the blocker and was left alone.

### New, different blocker: CAS immutability vs a full output_base
With the item cache fixed, a full `bzl --output_base=<mount>/ob build …` gets through
git-level operations but fails while **fetching external repos**:
`Error extracting dist.tar.gz … rules_nlo+/BUILD.bazel (Permission denied)`. This is
the inherent tension in hosting the *entire* base (not just an output tree) on a
CAS-dedup FS: `materialize`-on-close makes written blobs immutable (0444), but a full
base contains files that get **rewritten/chmod'd/re-extracted** (repo extraction,
mutable internal state). The `breakLink` copy-up covers `openItem(.readWrite)` but not
every mutation path Bazel's repo machinery uses. (Plain rewrite/chmod/`tar x` in the
mount *do* work — it's specific repo-extraction patterns that don't.)

### Options from here
1. **Pre-seed `external/` (and internal state) from a normal on-disk base** so nothing
   mutable is fetched/written in the mount — then only compile *outputs* write through
   it (the part we actually want deduped).
2. **Harden CAS COW** so `breakLink` fires on every mutation entry point
   (create-over-existing, chmod/setattr, truncate, extraction), making repo fetch
   robust. Also drop the stray `O_SYMLINK` in `createItem`'s regular-file create.
3. **Scope CAS-dedup to output-like paths only** (skip `external/`), so repos stay
   plain files.

Net: the passthrough is now a **correct general-purpose FS** for git/normal workloads
(goal A delivered). Making it host a *full Bazel output base* additionally needs the
mutable-file/immutability conflict resolved (options above).

## 14. output_base-in-mount: bugs fixed, and the fundamental wall (binary exec)

Pursued "the whole `--output_base` lives in the CAS mount, no output service". This
avoids §11's stale-cache wall (Bazel is the only writer) but exercises the full range
of filesystem operations. Fixed a long series of real passthrough bugs so the build
progressed from "crash at setup" to "all repos fetched + 11 min of analysis":

- **Item cache re-keyed** from backing inode → `(parent inode, name)` (`ItemKey`): CAS
  dedup shares inodes across paths, so the inode-keyed cache returned the wrong item.
  This fixed the flaky ENOENT/ENODATA (git init/commit went 15/15).
- **Extended attributes** implemented (`FSVolume.XattrOperations`) — killed the
  AppleDouble `._` sidecars and their errors.
- **`renameItem`/`createItem`/`createSymbolicLink`/`removeItem`/`lookupItem`: keep the
  directory fd open** (closed on reclaim) instead of an open/close-per-op churn that
  raced under concurrency (partial deletes → rmdir ENOTEMPTY). Raised RLIMIT_NOFILE.
- **`enumerateDirectory`**: iterate a private `dup` of the dir fd (+`closedir`), and use
  an **index-based cookie** (rewind+skip) instead of `telldir`/`seekdir` — those offsets
  aren't valid across the fresh `DIR*` opened per call, so paginated listings skipped
  entries (again → rmdir ENOTEMPTY on repo dirs like the android SDK `res/anim`).
- **`synchronize(flags:)`**: was `fsync(rootItem.fd)` on a *directory* fd → EBADF on
  macOS → git's packfile fsync failed. Made best-effort.
- **`write`**: open the item read-write if its fd is closed — mmap write-back
  (page-out) arrives with no preceding open, and `pwrite(-1)` failed EBADF (git's
  mmap'd packfile writes).
- **CAS made mutable** (dropped forced 0444) + **COW-on-chmod** in `setAttributes`
  (breakLink before metadata mutation) so repo extraction that rewrites/chmods deduped
  files doesn't hit EACCES / corrupt dedup siblings.
- **`.git` files excluded from CAS** (kept as plain regular files).
- **`createLink`** implemented via `linkat` — sysroot tarballs ship hard-linked files;
  the stub returned ENOTSUP and crashed Bazel's decompressor.

**Result:** `bzl --output_base=<mount>/ob build //src:libclient.so` now fetches every
external repo through the mount (git fetch, http_archive, hard-linked tarballs, Android
SDKs) and runs ~11 min of analysis (thousands of targets configured) — no FS errors.

### The wall: executing native binaries from the mount hangs
Analysis finally fails in a repo rule that runs a downloaded Python/conan interpreter
(`rules_nlo` → `run_conan_home`). Minimal repro: a freshly-compiled (ad-hoc-signed)
Mach-O runs fine from normal disk but **hangs indefinitely when executed from the
mount**. During the hang the FSKit extension is **idle — it never receives a read
request**; the process sits in kernel sleep. So the kernel's exec / code-signing /
mmap **pager** path blocks *before* reaching the extension: a passthrough that serves
`read`/`write` does not satisfy the executable-mapping path, which wants the
block/paging protocol (`FSVolumeExtent` `blockmapFile`/`completeIO` — a block-device
model that doesn't fit an fd-backed passthrough).

This is **fatal for hosting `output_base` in the mount**: repo rules exec interpreters
(python/conan) and the build execs toolchain wrappers from `external/`, all inside the
base. It's a kernel↔FSKit↔VM limitation, not a discrete op bug patchable in the
extension. Combined with §2–4 (analysis/metadata latency: the 11-min analysis), the
verdict stands: **use the validated bb_clientd path for the benchmark**; the BridgeFS
passthrough is now a capable general-purpose FS for read/write/rename/dedup workloads
(git works end-to-end) but cannot host a Bazel output base that executes binaries.

## 15. macOS NFS client async-writeback data loss (root-caused; fixed with socket buffers)

Full uncached RBE builds through the bb_clientd mount corrupted locally-written
FileWrite outputs (~every build): zero-holes starting at 32 KiB block boundaries in
valdi `explicit_input_list.json` files, which — with `--remote_upload_local_results` —
poisoned the shared EngFlow cache with self-consistent corrupt blobs.

**Root cause (measured at both ends in a single run):** the macOS kernel NFS client
(Darwin 25.5, NFSv4.1 over an AF_LOCAL socket) silently loses write chunks from its
async writeback: the WRITE RPC for the lost range is **never issued**. Client-side
ktrace (`debug_ctl=0x111C`, DKIO io_start/io_end pairing) shows every issued write
completing with success; server-side probes (opWrite/VirtualWrite/pool write-range
tracking, sequence/replay/rejection counters, connection lifecycle) show the range
never arrived and nothing was dropped in bb_clientd — and ONC-RPC record framing means
any mid-stream byte loss would desync the connection permanently, which never
happened. Trigger: socket backpressure — `net.local.stream.{recv,send}space` defaults
to 8 KiB while the client pushes ~33 KiB WRITE records from many writeback threads.

**Fix (production):** grow the socket buffers — 4 MiB SetReadBuffer/SetWriteBuffer on
accepted connections (nfsv4_mount_darwin.go) + `net.local.stream.*space=1048576`
sysctls (asserted by the launch script; they reset on reboot). Validated clean; mount
stays async. `MNT_SYNCHRONOUS` as a mount(2) flag also stops the loss (validated 5/5
together with buffers) at a write-latency cost — kept as a documented fallback.
Bonus fix kept: bb-remote-execution's NFSv4.1 opSequence duplicate-request path never
registered its wait channel (`append(slot.currentSequenceWaiters)` missing `ch`),
wedging the connection if a client retransmits while the original request is in
flight — upstreamable. Exact kernel line not pinpointed: DTrace requires disabling
SIP, which black-screens this Mac after login.
