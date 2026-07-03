#!/bin/bash
# Wire up a local bb_clientd backed by the BridgeFS FSKit mount on macOS:
#
#   1. build + install + enable the BridgeFS FSKit extension (via the InMemoryFS
#      scripts), so macOS knows the "BridgeFS" filesystem type.
#   2. build + run bb_clientd configured (configs/bb_clientd_fskit_local.jsonnet)
#      to serve its virtual filesystem over the fsmount gRPC service on
#      localhost:9999 — which BridgeFS connects to — and automount it at
#      ~/bb_clientd. CAS/AC/execution come from a local RBE on localhost:8980.
#
# bb-remote-execution is overridden to the local fskit-bridge checkout (which has
# the fskit mount backend), so MODULE.bazel stays unmodified.
#
# Prereqs:
#   - a Buildbarn RBE/storage frontend listening on localhost:8980
#   - the BridgeFS sources at $DEVFS/InMemoryFS and bb-remote-execution at $BBRE
set -euo pipefail

DEVFS="${DEVFS:-$HOME/Snapchat/Dev/virtualfs}"
BBRE="${BBRE:-$HOME/Snapchat/Dev/bb-remote-execution}"
CLIENTD="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$CLIENTD/configs/bb_clientd_fskit_local.jsonnet"
MOUNTPOINT="$HOME/Snapchat/Dev/.cache/bb_clientd"
INMEM="$DEVFS/InMemoryFS/scripts"

say() { printf "\033[1;34m>> %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m✗ %s\033[0m\n" "$*"; }

[ -d "$BBRE" ] || { err "bb-remote-execution not found at $BBRE (set BBRE=...)"; exit 1; }
[ -d "$INMEM" ] || { err "InMemoryFS scripts not found at $INMEM (set DEVFS=...)"; exit 1; }

# 1. BridgeFS extension: build + install + force-enable.
say "building + installing the BridgeFS FSKit extension"
bash "$INMEM/10-build.sh"
bash "$INMEM/20-install-and-enable.sh"

# 2. Clear any stale mount left over at the bb_clientd mountpoint.
if mount | grep -q " $MOUNTPOINT "; then
  say "unmounting stale mount at $MOUNTPOINT"
  umount "$MOUNTPOINT" 2>/dev/null || diskutil unmount force "$MOUNTPOINT" 2>/dev/null || true
fi
mkdir -p "$MOUNTPOINT"

# 3. Build + run bb_clientd against the local fskit-bridge bb-remote-execution.
#    bb_clientd serves fsmount on localhost:9999 and automounts $MOUNTPOINT; it
#    runs in the foreground and unmounts on shutdown (Ctrl-C).
say "running bb_clientd (fsmount on localhost:9999 -> automount $MOUNTPOINT)"
cd "$CLIENTD"
exec bazel run \
  --override_module=com_github_buildbarn_bb_remote_execution="$BBRE" \
  //cmd/bb_clientd -- "$CONFIG"
