#!/bin/bash
# Launch bb_clientd fronting EngFlow REMOTE EXECUTION (NFSv4 mount, macOS).
# Same auth/token-refresher/mount as the cache-only launcher, but with the RBE
# config (schedulers + write-through CAS). Foreground; Ctrl-C unmounts + stops
# the refresher. Only one bb_clientd may use the mount/socket at a time.
#
# Config: configs/bb_clientd_engflow_rbe.jsonnet
set -euo pipefail

CLIENTD="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$CLIENTD/configs/bb_clientd_engflow_rbe.jsonnet"
CACHE="$HOME/Snapchat/Dev/.cache/bb_clientd"
MOUNT="$HOME/Snapchat/Dev/bb_clientd"
TOKEN_FILE="$CACHE/engflow_token"
BBRE="${BBRE:-$HOME/Snapchat/Dev/bb-remote-execution}"
BBS="${BBS:-$HOME/Snapchat/Dev/buildbarn/bb-storage}"
BBXDR="${BBXDR:-$HOME/Snapchat/Dev/go-xdr}"

if mount | grep -q " $MOUNT "; then
  umount "$MOUNT" 2>/dev/null || diskutil unmount force "$MOUNT" 2>/dev/null || true
fi
rm -f "$CACHE/grpc" "$CACHE/nfsv4"

mkdir -p \
  "$CACHE/ac/persistent_state" \
  "$CACHE/cas/persistent_state" \
  "$CACHE/outputs" \
  "$MOUNT"

# macOS unix-socket buffers default to 8 KiB, which backpressures the kernel
# NFS client's async writeback hard enough that it silently LOSES write chunks
# (zero-holes in build outputs). The server side grows its buffers in code
# (nfsv4_mount_darwin.go); this covers the client side. Resets on reboot, so
# assert it on every launch.
if [ "$(sysctl -n net.local.stream.recvspace)" -lt 1048576 ]; then
  sudo sysctl -w net.local.stream.recvspace=1048576 net.local.stream.sendspace=1048576
fi

# EngFlow sc-lca-1 token (aud=engflow.sc-corp.net matches the RBE lca audience)
# + background refresher.
printf '%s' "$(snapaccess --email "$(whoami)@c.snap.com" --autoRefresh jwt make --ttl=1h engflow.sc-corp.net)" > "$TOKEN_FILE"
"$CLIENTD/configs/refresh_engflow_token.sh" "$TOKEN_FILE" &
REFRESHER_PID=$!
trap 'kill "$REFRESHER_PID" 2>/dev/null || true' EXIT INT TERM

cd "$CLIENTD"
env OS="$(uname)" HOME="$HOME" bazel run \
  --override_module=com_github_buildbarn_bb_remote_execution="$BBRE" \
  --override_module=com_github_buildbarn_bb_storage="$BBS" \
  --override_module=com_github_buildbarn_go_xdr="$BBXDR" \
  //cmd/bb_clientd -- "$CONFIG"
