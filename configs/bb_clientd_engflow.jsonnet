// bb_clientd configuration for the mobile monorepo, backed by Snap's EngFlow
// remote CACHE (not remote execution). macOS only — exposes the virtual
// filesystem over NFSv4 (no FUSE / no kernel extension needed).
//
// Auth model (important):
//   EngFlow at Snap authenticates with a short-lived JWT carried in the
//   `sc-lca-1` gRPC header (see engflow_config/glb_test.sh). Bazel's own
//   credential helper is keyed on `*.sc-corp.net` and is NOT invoked for a
//   unix-socket endpoint, so it cannot mint the token for bb_clientd. Instead
//   Bazel attaches a fresh `sc-lca-1` header per build (via --remote_cache_header)
//   and bb_clientd FORWARDS + REUSES it on outgoing calls to EngFlow (including
//   the lazy CAS reads triggered by the NFS mount). See global.* below and the
//   companion launch script for the exact Bazel flags.
//
// Run with:  configs/launch_bb_clientd_engflow_macos.sh

local os = std.extVar('OS');
local home = std.extVar('HOME');
local cacheDirectory = home + '/Snapchat/Dev/.cache/bb_clientd';

// File holding the current EngFlow sc-lca-1 JWT. The launch script writes an
// initial token here and starts a background loop that rewrites it before it
// expires; bb_clientd reloads this file every 60s (see grpcClient below). This
// is how bb_clientd stays authenticated across arbitrarily long builds without
// Bazel ever supplying a token.
local tokenPath = cacheDirectory + '/engflow_token';

{
  // The single EngFlow cache cluster this daemon talks to. The key is the
  // instance-name PREFIX that Bazel must use (--remote_instance_name=engflow);
  // bb_clientd strips it before forwarding, yielding EngFlow's empty instance
  // name — matching how this repo talks to the cache directly (build:rc_gcp).
  clusters:: {
    engflow: 'engflow-cache-gcp-prod.sc-corp.net',
  },

  // Local on-disk cache sizes (tune to taste / free disk).
  casBlocksSizeBytes:: 100 * 1024 * 1024 * 1024,
  filePoolSizeBytes:: 100 * 1024 * 1024 * 1024,
  averageCasBlobSizeBytes:: 5 * 1024,
  casKeyLocationMapSizeBytes:: std.ceil((self.casBlocksSizeBytes * 66) / (self.averageCasBlobSizeBytes * 0.5)),

  acBlocksSizeBytes:: 1024 * 1024 * 1024,
  averageAcBlobSizeBytes:: 1024,
  acKeyLocationMapSizeBytes:: std.ceil((self.acBlocksSizeBytes * 66) / (self.averageAcBlobSizeBytes * 0.5)),

  maximumMessageSizeBytes: 16 * 1024 * 1024,
  maximumTreeSizeBytes: 256 * 1024 * 1024,

  // Use NFSv4 on macOS (the only supported virtual-fs transport there without
  // a kernel extension); FUSE elsewhere.
  useNFSv4:: os == 'Darwin',

  grpcClient:: function(hostname) {
    address: hostname + ':443',
    tls: {},
    // Authenticate to EngFlow ourselves: attach the sc-lca-1 JWT read from
    // tokenPath (auto-reloaded every 60s), and preserve Bazel's REv2 request
    // metadata. A header value must be a list of strings, hence [files.*].
    addMetadataJmespathExpression: {
      expression: |||
        {
          "sc-lca-1": [files.engflowToken],
          "build.bazel.remote.execution.v2.requestmetadata-bin": incomingGRPCMetadata."build.bazel.remote.execution.v2.requestmetadata-bin"
        }
      |||,
      files: [{ key: 'engflowToken', path: tokenPath }],
    },
    keepalive: {
      time: '60s',
      timeout: '30s',
    },
  },

  // Route by instance-name prefix to the EngFlow cache. The prefix is stripped
  // on outgoing requests.
  blobstoreConfig:: function() {
    demultiplexing: {
      instanceNamePrefixes: {
        [cluster]: { backend: {
          grpc: { client: $.grpcClient($.clusters[cluster]) },
        } }
        for cluster in std.objectFields($.clusters)
      },
    },
  },

  // When false (default): Bazel's uploaded results (with
  // --remote_upload_local_results) are written ONLY to bb_clientd's on-disk
  // local store; EngFlow is still READ as a fallback (and is the source of
  // CI-populated hits). Use this if you lack EngFlow write permission.
  // When true: also write results through to EngFlow (needs remote write perm).
  uploadResultsToRemote:: false,

  // On-disk local Action Cache store — the local write target / read primary
  // when uploadResultsToRemote is false.
  localActionCache:: { 'local': {
    keyLocationMapOnBlockDevice: { file: {
      path: cacheDirectory + '/ac/key_location_map',
      sizeBytes: $.acKeyLocationMapSizeBytes,
    } },
    keyLocationMapMaximumGetAttempts: 16,
    keyLocationMapMaximumPutAttempts: 64,
    oldBlocks: 1,
    currentBlocks: 5,
    newBlocks: 1,
    blocksOnBlockDevice: {
      source: { file: {
        path: cacheDirectory + '/ac/blocks',
        sizeBytes: $.acBlocksSizeBytes,
      } },
      spareBlocks: 1,
    },
    persistent: {
      stateDirectoryPath: cacheDirectory + '/ac/persistent_state',
      minimumEpochInterval: '300s',
    },
  } },

  // EngFlow CAS wrapped with a 5-minute FindMissingBlobs existence cache, to
  // cut down on redundant existence checks Bazel issues.
  casRemoteRead:: {
    existenceCaching: {
      backend: { label: 'clustersCAS' },
      existenceCache: {
        cacheSize: 1000 * 1000,
        cacheDuration: '300s',
        cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
      },
    },
  },

  // Bounded-concurrency replicator used to stream blobs into the local CAS.
  casReplicator:: {
    deduplicating: {
      concurrencyLimiting: {
        base: { 'local': {} },
        maximumConcurrency: 100,
      },
    },
  },

  blobstore: {
    actionCache: { demultiplexing: { instanceNamePrefixes: {
      // 'engflow' → UpdateActionResult writes to the local AC only;
      // GetActionResult falls back to EngFlow on a local miss. When
      // uploadResultsToRemote is true, write straight through to EngFlow.
      '': { backend:
        if $.uploadResultsToRemote then
          $.blobstoreConfig()
        else {
          readFallback: {
            primary: $.localActionCache,
            secondary: $.blobstoreConfig(),
            // Required for the AC read_fallback; copies ActionResults read from
            // EngFlow into the local AC (small protos). Use { noop: {} } to skip.
            replicator: { 'local': {} },
          },
        },
      },
    } } },
    contentAddressableStorage: { withLabels: {
      backend: { demultiplexing: { instanceNamePrefixes: {
        // 'engflow' → blob uploads (Put) land in the local CAS only; reads
        // check local first, then fall back to EngFlow (replicating hits into
        // local). When uploadResultsToRemote is true, uploads write through to
        // EngFlow (the original read-through-cache behavior).
        '': { backend:
          if $.uploadResultsToRemote then {
            readCaching: {
              slow: $.casRemoteRead,
              fast: { label: 'localCAS' },
              replicator: $.casReplicator,
            },
          } else {
            readFallback: {
              primary: { label: 'localCAS' },
              secondary: $.casRemoteRead,
              replicator: $.casReplicator,
            },
          },
        },
      } } },
      labels: {
        localCAS: { 'local': {
          keyLocationMapOnBlockDevice: { file: {
            path: cacheDirectory + '/cas/key_location_map',
            sizeBytes: $.casKeyLocationMapSizeBytes,
          } },
          keyLocationMapMaximumGetAttempts: 16,
          keyLocationMapMaximumPutAttempts: 64,
          oldBlocks: 1,
          currentBlocks: 5,
          newBlocks: 1,
          blocksOnBlockDevice: {
            source: { file: {
              path: cacheDirectory + '/cas/blocks',
              sizeBytes: $.casBlocksSizeBytes,
            } },
            spareBlocks: 1,
            dataIntegrityValidationCache: {
              cacheSize: 100000,
              cacheDuration: '14400s',
              cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
            },
          },
          persistent: {
            stateDirectoryPath: cacheDirectory + '/cas/persistent_state',
            minimumEpochInterval: '300s',
          },
        } },
        clustersCAS: $.blobstoreConfig(),
      },
    } },
  },

  // The unix-socket gRPC endpoint Bazel points --remote_cache and
  // --experimental_remote_output_service at.
  grpcServers: [{
    listenPaths: [cacheDirectory + '/grpc'],
    authenticationPolicy: { allow: {} },
  }],

  // NFSv4 (macOS) virtual filesystem. bb_clientd performs the mount itself
  // over the unix socket below — no FUSE, no kernel extension.
  mount: {
    mountPath: home + '/Snapchat/Dev/bb_clientd',
  } + if $.useNFSv4 then {
    nfsv4: {
      enforcedLeaseTime: '120s',
      announcedLeaseTime: '60s',
    } + {
      Darwin: { darwin: {
        socketPath: cacheDirectory + '/nfsv4',
        // Use NFSv4.1 (sessions) instead of the 4.0 default: lower per-op
        // round-trip overhead, which dominates on a chatty tree like bazel-out.
        minorVersion: 1,
        // macOS caches ACCESS-check results per vnode in a small fixed-size
        // cache. On large trees it thrashes, forcing a synchronous ACCESS RPC
        // on nearly every open/stat and stalling reads. Enlarge it.
        accessCacheSize: 100000,
      } },
      Linux: { linux: { mountOptions: ['vers=4.1'] } },
    }[os],
  } else {
    fuse: {
      directoryEntryValidity: '300s',
      inodeAttributeValidity: '300s',
      allowOther: true,
    },
  },

  filePool: { blockDevice: { file: {
    path: cacheDirectory + '/filepool',
    sizeBytes: $.filePoolSizeBytes,
  } } },

  outputPathPersistency: {
    stateDirectoryPath: cacheDirectory + '/outputs',
    maximumStateFileSizeBytes: 1024 * 1024 * 1024,
    maximumStateFileAge: '604800s',
  },

  // Keep far more unmarshaled REv2 Directory objects in memory. Every NFS
  // lookup into a lazily-loaded tree needs its parent Directory; a small cache
  // means re-fetching + re-unmarshaling them repeatedly. ~100 MiB here.
  directoryCache: {
    maximumCount: 100000,
    maximumSizeBytes: 1024 * self.maximumCount,
    cacheReplacementPolicy: 'LEAST_RECENTLY_USED',
  },

  maximumFileSystemRetryDelay: '300s',

  global: {
    logPaths: [cacheDirectory + '/log'],
  },
}
