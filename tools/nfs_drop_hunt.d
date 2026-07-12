#!/usr/sbin/dtrace -s
/*
 * nfs_drop_hunt.d — catch the macOS NFS client discarding dirty write data
 * before a WRITE RPC is ever issued.
 *
 * Requires: SIP with DTrace restrictions disabled (csrutil enable --without dtrace
 * from Recovery). Target kext: com.apple.filesystems.nfs (Darwin 25.5).
 *
 * struct nfsbuf field offsets computed from the kext source (apple-oss NFS,
 * nfsnode.h) via nfsbuf_offsets.c — verify with the CALIBRATE probe below:
 * nb_bufsize must consistently read 32768 for data buffers, else offsets are
 * wrong and all bets are off.
 *
 * Event tags (grep targets):
 *   CAL    calibration (bufsize sanity)
 *   RPC    WRITE RPC issuance ledger (nfs_buf_write_rpc)
 *   FIN    write completion accounting (nfs_buf_write_finish)
 *   DROP!  dirty buffer being released/invalidated WITHOUT being written
 *   VINV   vinvalbuf without V_SAVE (discard-without-flush request)
 *   DUMP!  UPL abort with UPL_ABORT_DUMP_PAGES (page contents discarded)
 *   PGINV  nfs_buf_page_inval_internal on a buffer with a dirty range
 */
#pragma D option quiet
#pragma D option bufsize=256m
#pragma D option switchrate=20hz
#pragma D option dynvarsize=64m

/* ---- struct nfsbuf offsets (from nfsbuf_offsets.c) ---- */
inline int OFF_nb_lblkno   = 0x38;
inline int OFF_nb_dirty    = 0x90;   /* nfsbufpgs.pages[0]; 32K buf = 2 x 16K pages -> low bits */
inline int OFF_nb_np       = 0xd8;
inline int OFF_nb_flags    = 0xf8;
inline int OFF_nb_bufsize  = 0x100;
inline int OFF_nb_error    = 0x104;
inline int OFF_nb_dirtyoff = 0x120;
inline int OFF_nb_dirtyend = 0x128;
inline int OFF_nb_offio    = 0x130;
inline int OFF_nb_endio    = 0x138;

/* ---- flag constants ---- */
inline uint32_t NB_ERROR = 0x0800;
inline uint32_t NB_INVAL = 0x2000;
inline uint32_t NB_READ  = 0x100000;
inline int      V_SAVE   = 0x1;
inline int      UPL_ABORT_DUMP_PAGES = 0x10;

/* field accessors */
#define BP_LBLK(bp)   (*(int64_t *)((uintptr_t)(bp) + OFF_nb_lblkno))
#define BP_DIRTY(bp)  (*(uint64_t *)((uintptr_t)(bp) + OFF_nb_dirty))
#define BP_NP(bp)     (*(uintptr_t *)((uintptr_t)(bp) + OFF_nb_np))
#define BP_FLAGS(bp)  (*(uint32_t *)((uintptr_t)(bp) + OFF_nb_flags))
#define BP_BUFSZ(bp)  (*(uint32_t *)((uintptr_t)(bp) + OFF_nb_bufsize))
#define BP_ERR(bp)    (*(int32_t *)((uintptr_t)(bp) + OFF_nb_error))
#define BP_DOFF(bp)   (*(int64_t *)((uintptr_t)(bp) + OFF_nb_dirtyoff))
#define BP_DEND(bp)   (*(int64_t *)((uintptr_t)(bp) + OFF_nb_dirtyend))
#define BP_OFFIO(bp)  (*(int64_t *)((uintptr_t)(bp) + OFF_nb_offio))
#define BP_ENDIO(bp)  (*(int64_t *)((uintptr_t)(bp) + OFF_nb_endio))

BEGIN
{
	printf("nfs_drop_hunt armed at %Y\n", walltimestamp);
	calibrated = 0;
}

/* ---------- calibration: offsets sane? (first 5 write RPCs) ---------- */
fbt:com.apple.filesystems.nfs:nfs_buf_write_rpc:entry
/calibrated < 5/
{
	calibrated++;
	printf("CAL bufsize=%d (want 32768) lblk=%d doff=%d dend=%d\n",
	    BP_BUFSZ(arg0), BP_LBLK(arg0), BP_DOFF(arg0), BP_DEND(arg0));
}

/* ---------- issuance ledger: every WRITE RPC ---------- */
fbt:com.apple.filesystems.nfs:nfs_buf_write_rpc:entry
{
	printf("RPC t=%d np=%p lblk=%d doff=%d dend=%d flags=%x\n",
	    timestamp, BP_NP(arg0), BP_LBLK(arg0), BP_DOFF(arg0), BP_DEND(arg0),
	    BP_FLAGS(arg0));
}

/* ---------- completion accounting ---------- */
fbt:com.apple.filesystems.nfs:nfs_buf_write_finish:entry
{
	printf("FIN t=%d np=%p lblk=%d err=%d offio=%d endio=%d doff=%d dend=%d dirty=%x flags=%x\n",
	    timestamp, BP_NP(arg0), BP_LBLK(arg0), BP_ERR(arg0),
	    BP_OFFIO(arg0), BP_ENDIO(arg0), BP_DOFF(arg0), BP_DEND(arg0),
	    BP_DIRTY(arg0), BP_FLAGS(arg0));
}

/* ---------- THE MONEY PROBE: dirty data released as invalid ----------
 * A buffer being released with NB_INVAL while still holding a dirty byte
 * range or dirty page bits = data discarded without a write. */
fbt:com.apple.filesystems.nfs:nfs_buf_release:entry
/(BP_FLAGS(arg0) & NB_INVAL) && !(BP_FLAGS(arg0) & NB_READ) &&
 (BP_DEND(arg0) > BP_DOFF(arg0) || BP_DIRTY(arg0) != 0)/
{
	printf("DROP! t=%d np=%p lblk=%d doff=%d dend=%d dirty=%x flags=%x err=%d\n",
	    timestamp, BP_NP(arg0), BP_LBLK(arg0), BP_DOFF(arg0), BP_DEND(arg0),
	    BP_DIRTY(arg0), BP_FLAGS(arg0), BP_ERR(arg0));
	stack();
}

/* ---------- vinvalbuf without V_SAVE: discard-without-flush ---------- */
fbt:com.apple.filesystems.nfs:nfs_vinvalbuf2:entry
/!(arg1 & V_SAVE)/
{
	printf("VINV t=%d vp=%p flags=%x nosave\n", timestamp, arg0, arg1);
	stack();
}

fbt:com.apple.filesystems.nfs:nfs_vinvalbuf_internal:entry
/!(arg1 & V_SAVE)/
{
	printf("VINV-INT t=%d np=%p flags=%x nosave\n", timestamp, arg0, arg1);
	stack();
}

/* ---------- UPL page dumps: VM-level discard of page contents ----------
 * ubc_upl_abort_range(upl, offset, size, flags) — kernel proper, so no
 * struct offsets needed. Only DUMP_PAGES aborts destroy data. Stack shows
 * whether the caller is the NFS kext. */
fbt:mach_kernel:ubc_upl_abort_range:entry
/arg3 & UPL_ABORT_DUMP_PAGES/
{
	printf("DUMP! t=%d upl=%p off=%d size=%d flags=%x\n",
	    timestamp, arg0, arg1, arg2, arg3);
	stack();
}

fbt:mach_kernel:ubc_upl_abort:entry
/arg1 & UPL_ABORT_DUMP_PAGES/
{
	printf("DUMP! t=%d upl=%p flags=%x (whole-upl)\n", timestamp, arg0, arg1);
	stack();
}

/* ---------- VM page-inval consult on a dirty buffer ---------- */
fbt:com.apple.filesystems.nfs:nfs_buf_page_inval_internal:entry
{
	printf("PGINV t=%d vp=%p off=%d\n", timestamp, arg0, arg1);
}

END
{
	printf("nfs_drop_hunt done at %Y\n", walltimestamp);
}
