// Compute struct nfsbuf field offsets for the DTrace script, using the exact
// field sequence from the Apple NFS kext source (nfsnode.h). Kernel-only types
// stubbed with their RELEASE-kernel-ABI equivalents.
#include <stdio.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <sys/queue.h>

typedef struct { uint32_t ref_count; } os_refcnt_t;   // os/refcnt.h, RELEASE (no debug group ptr)
typedef int64_t daddr64_t;
typedef struct { uint64_t pages[8]; } nfsbufpgs;
typedef void *nfsnode_t;
typedef void *kauth_cred_t;

struct nfsbuf {
	LIST_ENTRY(nfsbuf)      nb_hash;
	LIST_ENTRY(nfsbuf)      nb_vnbufs;
	TAILQ_ENTRY(nfsbuf)     nb_free;
	os_refcnt_t             nb_refs;
	daddr64_t               nb_lblkno;
	uint64_t                nb_verf;
	time_t                  nb_timestamp;
	nfsbufpgs               nb_valid;
	nfsbufpgs               nb_dirty;
	caddr_t                 nb_data;
	nfsnode_t               nb_np;
	kauth_cred_t            nb_rcred;
	kauth_cred_t            nb_wcred;
	void *                  nb_pagelist;
	volatile uint32_t       nb_flags;
	volatile uint32_t       nb_lflags;
	uint32_t                nb_bufsize;
	int                     nb_error;
	int                     nb_commitlevel;
	off_t                   nb_validoff;
	off_t                   nb_validend;
	off_t                   nb_dirtyoff;
	off_t                   nb_dirtyend;
	off_t                   nb_offio;
	off_t                   nb_endio;
	uint64_t                nb_rpcs;
};

#define P(f) printf("#define OFF_%-14s 0x%lx\n", #f, offsetof(struct nfsbuf, f))
int main(void) {
	P(nb_lblkno); P(nb_valid); P(nb_dirty); P(nb_np); P(nb_pagelist);
	P(nb_flags); P(nb_lflags); P(nb_bufsize); P(nb_error);
	P(nb_dirtyoff); P(nb_dirtyend); P(nb_offio); P(nb_endio);
	printf("// sizeof(struct nfsbuf) = 0x%lx\n", sizeof(struct nfsbuf));
	return 0;
}
