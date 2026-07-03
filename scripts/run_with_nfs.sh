#!/bin/bash
# Wire up a local bb_clientd backed by the built-in NFSv4 mount on macOS — the
# BASELINE for comparing against the BridgeFS FSKit mount (run_with_fskit.sh):
#
#   1. stop any bb_clientd already serving the shared paths (mountpoint, gRPC
#      socket and cache directory are the same for both backends, so only one
#      runs at a time).
#   2. build + run bb_clientd configured (configs/bb_clientd_nfs_local.jsonnet)
#      to expose its virtual filesystem over NFSv4.1 on a UNIX socket and mount
#      it at ~/bb_clientd. CAS/AC/execution come from a local RBE on
#      localhost:8980.
#
# bb-remote-execution is overridden to the local fskit-bridge checkout so BOTH
# backends run the same bb-remote-execution code base — a fair comparison.
#
# Prereqs:
#   - a Buildbarn RBE/storage frontend listening on localhost:8980
#   - bb-remote-execution at $BBRE
set -euo pipefail

BBRE="${BBRE:-$HOME/bb-remote-execution}"
CLIENTD="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$CLIENTD/configs/bb_clientd_nfs_local.jsonnet"
MOUNTPOINT="$HOME/bb_clientd"

say() { printf "\033[1;34m>> %s\033[0m\n" "$*"; }
err() { printf "\033[1;31m✗ %s\033[0m\n" "$*"; }

[ -d "$BBRE" ] || { err "bb-remote-execution not found at $BBRE (set BBRE=...)"; exit 1; }

# 1. Stop a bb_clientd that is already serving the shared paths, and clear any
#    stale mount (FSKit or NFS) at the mountpoint.
if pgrep -f "bb_clientd.*bb_clientd_.*_local.jsonnet" >/dev/null 2>&1; then
  say "stopping running bb_clientd"
  pkill -f "bb_clientd.*bb_clientd_.*_local.jsonnet" || true
  sleep 1
fi
if mount | grep -q " $MOUNTPOINT "; then
  say "unmounting stale mount at $MOUNTPOINT"
  umount "$MOUNTPOINT" 2>/dev/null || diskutil unmount force "$MOUNTPOINT" 2>/dev/null || true
fi
mkdir -p "$MOUNTPOINT"

# 2. Build + run bb_clientd. It serves NFSv4 on a UNIX socket, mounts
#    $MOUNTPOINT itself, runs in the foreground and unmounts on shutdown
#    (Ctrl-C).
say "running bb_clientd (NFSv4 -> mount $MOUNTPOINT)"
cd "$CLIENTD"
exec bazel run \
  --override_module=com_github_buildbarn_bb_remote_execution="$BBRE" \
  //cmd/bb_clientd -- "$CONFIG"
