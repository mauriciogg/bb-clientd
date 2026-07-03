// bb_clientd configuration for local development on macOS using the built-in
// NFSv4 mount — the coherency/performance BASELINE to compare BridgeFS (the
// FSKit mount, bb_clientd_fskit_local.jsonnet) against. Everything except the
// `mount` block is identical to the FSKit config: same RBE frontend
// (localhost:8980), same gRPC socket, same cache/filepool/persistency paths,
// and the same mountpoint (~/bb_clientd) so the exact same Bazel invocation
// works against either backend. Run one backend at a time.
//
// Run with scripts/run_with_nfs.sh.

local home = std.extVar('HOME');
local cacheDirectory = home + '/.cache/bb_clientd';

// The local RBE frontend (bb-storage / bb-remote-execution) — plaintext, no TLS.
local rbe = { address: 'localhost:8980' };

{
  maximumMessageSizeBytes: 16 * 1024 * 1024,
  maximumTreeSizeBytes: 256 * 1024 * 1024,

  // CAS and Action Cache, both served by the local RBE frontend.
  blobstore: {
    actionCache: { grpc: { client: rbe } },
    contentAddressableStorage: { withLabels: {
      backend: { label: 'cas' },
      labels: { cas: { grpc: { client: rbe } } },
    } },
  },

  // Execution requests (the empty instance-name prefix matches everything).
  schedulers: {
    '': { endpoint: rbe },
  },

  // gRPC server Bazel talks to (UNIX socket under the cache directory).
  grpcServers: [{
    listenPaths: [cacheDirectory + '/grpc'],
    authenticationPolicy: { allow: {} },
  }],

  // Expose the virtual filesystem over the built-in NFSv4.1 server; the kernel
  // NFS client connects through the UNIX socket and bb_clientd performs the
  // mount itself.
  mount: {
    mountPath: home + '/bb_clientd',
    nfsv4: {
      enforcedLeaseTime: '120s',
      announcedLeaseTime: '60s',
      darwin: { socketPath: cacheDirectory + '/nfsv4' },
    },
  },

  // Local scratch storage for files created under "scratch"/"outputs".
  filePool: { blockDevice: { file: {
    path: cacheDirectory + '/filepool',
    sizeBytes: 10 * 1024 * 1024 * 1024,
  } } },

  outputPathPersistency: {
    stateDirectoryPath: cacheDirectory + '/outputs',
    maximumStateFileSizeBytes: 1024 * 1024 * 1024,
    maximumStateFileAge: '604800s',
  },

  directoryCache: {
    maximumCount: 10000,
    maximumSizeBytes: 1024 * 10000,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },

  maximumFileSystemRetryDelay: '300s',

  global: {
    logPaths: [cacheDirectory + '/log'],
  },
}
