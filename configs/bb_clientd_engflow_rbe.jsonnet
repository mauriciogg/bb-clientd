// bb_clientd fronting Snap's EngFlow REMOTE EXECUTION cluster (not just cache).
// Bazel points --remote_executor + --remote_cache at bb_clientd's unix socket;
// bb_clientd proxies Execute calls to the EngFlow scheduler and CAS/AC to
// EngFlow, while exposing outputs via the NFS mount (build-without-the-bytes).
//
// Reuses everything from bb_clientd_engflow.jsonnet (NFS mount, sc-lca-1 token
// file auth, unix-socket gRPC server, local CAS read-cache) and only changes:
//   - the cluster endpoint -> the RBE endpoint (serves CAS+AC+Execution),
//   - write-through CAS/AC (remote execution needs Bazel's uploaded inputs to
//     land in EngFlow's CAS so the workers can read them — local-only writes
//     would make the executor unable to see the inputs),
//   - a schedulers entry so Execute is routed to EngFlow.
//
// Run with configs/launch_bb_clientd_engflow_rbe_macos.sh. Only one bb_clientd
// instance can use the mount/socket at a time — stop the cache-only one first.

local base = import 'bb_clientd_engflow.jsonnet';

base {
  // EngFlow RBE prod endpoint (from .bazelrc.rbe: rbe_prod uses this for both
  // remote_cache and remote_executor). Key on the EMPTY instance-name prefix so
  // Bazel needs no --remote_instance_name: an empty instance name matches, and
  // is forwarded to EngFlow unchanged (EngFlow RBE expects the empty instance
  // name — a non-empty 'engflow-rbe' would be forwarded as-is and rejected).
  clusters:: { '': 'engflow-cache-rbe-gcp-prod.sc-corp.net' },

  // Write through to EngFlow's CAS/AC (required for remote execution).
  uploadResultsToRemote:: true,

  // Route Execute/WaitExecution to the EngFlow scheduler, same endpoint +
  // prefix-stripping as the blobstore.
  schedulers: {
    [cluster]: { endpoint: $.grpcClient($.clusters[cluster]) }
    for cluster in std.objectFields($.clusters)
  },
}
