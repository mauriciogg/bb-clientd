// bb-clientd configuration that:
//   1. exposes Buildbarn's virtual filesystem through the macOS FSKit bridge
//      (instead of NFSv4/FUSE), and
//   2. backs the "outputs" tree with the BuildBuddy remote cache / RBE using
//      our anonymous account (config:anon-bes in ~/buildbuddy/shared.bazelrc).
//
// It reuses the stock example config (bb_clientd.jsonnet) and overrides only
// what's needed: the `mount` block and the cluster routing / credentials.
//
// FSKit bridge: this bb-clientd process listens on a UNIX socket inside the App
// Group container shared with the BridgeFS FSKit extension — the one path a
// sandboxed extension can reach. autoMount=false, so bb-clientd only starts the
// bridge server + writes the enable marker; you run `mount` separately (the
// extension must be installed + enabled first; see InMemoryFS/scripts).
//
// BuildBuddy routing: bb_clientd routes by the *prefix* of the instance name.
// Bazel uses `--remote_instance_name=buildbuddy`; bb_clientd matches the
// `buildbuddy` prefix, strips it, and forwards to remote.buildbuddy.io:443 with
// an empty instance name (what the anon account expects). Credentials are
// injected here (x-buildbuddy-api-key), so Bazel never has to carry them on the
// cache/exec path — it just talks to the local UNIX socket.

local base = import 'bb_clientd.jsonnet';

local groupContainer =
  std.extVar('HOME') + '/Library/Group Containers/group.com.mauriciogalindo.inmemoryfs';

// BuildBuddy anonymous API key, from ~/buildbuddy/shared.bazelrc (config:anon-bes):
//   common:anon-bes --remote_header=x-buildbuddy-api-key=che5d1dAwgzLEbe9ll5B
local buildbuddyApiKey = 'che5d1dAwgzLEbe9ll5B';

base {
  // Instance-name prefix -> backend hostname. The prefix is stripped on
  // outgoing requests, so `--remote_instance_name=buildbuddy` reaches
  // remote.buildbuddy.io with an empty instance name.
  clusters:: { buildbuddy: 'remote.buildbuddy.io' },

  // Same shape as the stock grpcClient, but inject BuildBuddy's API-key header
  // (x-buildbuddy-api-key) rather than a generic Authorization header.
  grpcClient:: function(hostname, authorizationHeader, proxyURL) {
    address: hostname + ':443',
    tls: {},
    addMetadata: [
      { header: 'x-buildbuddy-api-key', values: [buildbuddyApiKey] },
    ],
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
    proxyUrl: proxyURL,
  },

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
