// bb_clientd configuration for local development on macOS using the BridgeFS
// FSKit mount. It connects to a Buildbarn RBE/storage frontend running locally
// on localhost:8980 (plaintext) for CAS, AC and execution, and exposes its
// virtual filesystem over the fsmount gRPC service that the BridgeFS FSKit
// extension connects to.
//
// Run with scripts/run_with_fskit.sh (which overrides bb-remote-execution to
// the local fskit-bridge checkout and builds/installs BridgeFS first).

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

  // Expose the virtual filesystem via the BridgeFS FSKit extension. bb_clientd
  // runs the fsmount gRPC server (which BridgeFS connects to) and, because
  // automount is set, performs the `mount` itself once the server is up.
  mount: {
    mountPath: home + '/bb_clientd',
    fskit: {
      server: {
        // BridgeFS connects here; must match Constants.serverHost:serverPort in
        // the extension (localhost:9999).
        listenAddresses: ['localhost:9999'],
        authenticationPolicy: { allow: {} },
      },
      automount: {
        // FSShortName from the BridgeFS extension's Info.plist.
        fsName: 'BridgeFS',
      },
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
