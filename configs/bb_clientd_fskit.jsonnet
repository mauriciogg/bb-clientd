// bb-clientd configuration that exposes the virtual filesystem through the macOS
// FSKit bridge instead of NFSv4/FUSE. It reuses the stock example config and only
// overrides the `mount` block.
//
// The bridge server (this bb-clientd process) listens on a UNIX socket inside the
// App Group container shared with the BridgeFS FSKit extension — the one path a
// sandboxed extension can reach. auto_mount=false so bb-clientd only starts the
// server + writes the enable marker; you run `mount` separately (the extension
// must be installed + enabled first; see the BridgeFS scripts).

local base = import 'bb_clientd.jsonnet';

local groupContainer =
  std.extVar('HOME') + '/Library/Group Containers/group.com.mauriciogalindo.inmemoryfs';

base {
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
