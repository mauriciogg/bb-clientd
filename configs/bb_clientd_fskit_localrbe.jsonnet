// bb-clientd configuration that:
//   1. exposes Buildbarn's virtual filesystem through the macOS FSKit bridge, and
//   2. backs the "outputs" tree with a LOCAL Buildbarn RBE cluster (CAS + AC +
//      execution) at grpc://localhost:8980, instance name "local" — instead of
//      the BuildBuddy anonymous cache (which evicts blobs mid-build and causes the
//      "Input/output error" / NotFound failures).
//
// Bazel side (no bb-fskit-rbe needed; point everything at the local bb-clientd
// socket and use instance name `local`):
//   bazel build \
//     --remote_cache=unix:///Users/mauricio/.cache/bb_clientd/grpc \
//     --remote_executor=unix:///Users/mauricio/.cache/bb_clientd/grpc \
//     --remote_instance_name=local \
//     --experimental_remote_output_service=unix:///Users/mauricio/.cache/bb_clientd/grpc \
//     --experimental_remote_output_service_output_path_prefix=/Users/mauricio/bb_clientd/outputs \
//     --remote_download_minimal //your:target
//
// Routing notes:
//   - The base config (bb_clientd.jsonnet) RESERVES the `local` instance-name
//     prefix for bb-clientd's OWN on-disk cache. We deliberately OVERRIDE the
//     whole blobstore + schedulers so `local` is instead forwarded to the RBE.
//   - blobstore backends are DIRECT `grpc` (no demultiplexing), so the instance
//     name passes through UNCHANGED — Bazel's `local` reaches the RBE as `local`.
//   - the scheduler uses the empty-prefix `''` catch-all (matches any instance
//     name, strips nothing, adds nothing), so Execute requests also forward
//     `local` unchanged.

local base = import 'bb_clientd.jsonnet';

local groupContainer =
  std.extVar('HOME') + '/Library/Group Containers/group.com.mauriciogalindo.inmemoryfs';

// Override on the command line if your RBE lives elsewhere:
//   RBE_ADDRESS=host:port  (the script passes it through as an extVar default)
local rbeAddress = 'localhost:8980';

// Plaintext gRPC client to the local RBE. NOTE: no `tls` field => plaintext
// (matches Bazel's grpc:// scheme). Adding `tls: {}` would switch to TLS.
local rbeClient = {
  address: rbeAddress,
  // Forward Bazel's RequestMetadata so the cluster gets tool/invocation info.
  addMetadataJmespathExpression: {
    expression: |||
      {
        "build.bazel.remote.execution.v2.requestmetadata-bin": incomingGRPCMetadata."build.bazel.remote.execution.v2.requestmetadata-bin"
      }
    |||,
  },
  keepalive: {
    time: '60s',
    timeout: '30s',
  },
};

base {
  // CAS + Action Cache go straight to the local RBE. Direct `grpc` backends
  // forward the instance name as-is, so `local` is preserved. Because the RBE's
  // CAS is the same store the executors write to, lazily-materialized outputs are
  // always present — no eviction / NotFound / EIO like the anon BuildBuddy cache.
  blobstore: {
    actionCache: { grpc: { client: rbeClient } },
    contentAddressableStorage: { grpc: { client: rbeClient } },
  },

  // Route ALL execution requests to the local RBE scheduler. Empty prefix '' is
  // the catch-all; with no AddInstanceNamePrefix it forwards the instance name
  // verbatim (so `local` -> `local`).
  schedulers: {
    '': { endpoint: rbeClient },
  },

  // FSKit bridge mount (same as bb_clientd_fskit.jsonnet). Replaces the base
  // FUSE/NFSv4 mount block entirely.
  mount: {
    mountPath: std.extVar('HOME') + '/bb_clientd',
    fskit: {
      socketPath: groupContainer + '/fskit-bridge.sock',
      fsName: 'BridgeFS',
      // The path-URL source is ignored by the bridge; any dir works.
      sourcePath: std.extVar('HOME') + '/bb_clientd',
      // Let the operator trigger `mount` after the extension is enabled.
      autoMount: false,
    },
  },
}
