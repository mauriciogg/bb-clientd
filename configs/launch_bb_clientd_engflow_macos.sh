#!/bin/bash
# Launch bb_clientd on macOS backed by Snap's EngFlow remote cache, exposing the
# virtual filesystem over NFSv4 (no FUSE / kernel extension). Runs in the
# foreground; Ctrl-C unmounts and shuts down.
#
# Config: configs/bb_clientd_engflow.jsonnet
set -euo pipefail

CLIENTD="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$CLIENTD/configs/bb_clientd_engflow.jsonnet"
CACHE="$HOME/Snapchat/Dev/.cache/bb_clientd"
MOUNT="$HOME/Snapchat/Dev/bb_clientd"
TOKEN_FILE="$CACHE/engflow_token"

# Clear any stale mount / socket from a previous run.
if mount | grep -q " $MOUNT "; then
  umount "$MOUNT" 2>/dev/null || diskutil unmount force "$MOUNT" 2>/dev/null || true
fi
rm -f "$CACHE/grpc" "$CACHE/nfsv4"

mkdir -p \
  "$CACHE/ac/persistent_state" \
  "$CACHE/cas/persistent_state" \
  "$CACHE/outputs" \
  "$MOUNT"

# bb_clientd reads the EngFlow token from $TOKEN_FILE and fails to start if it's
# missing, so mint an initial one now (no trailing newline), then start the
# background refresher that keeps it fresh.
printf '%s' "$(snapaccess --email "$(whoami)@c.snap.com" --autoRefresh jwt make --ttl=1h engflow.sc-corp.net)" > "$TOKEN_FILE"

"$CLIENTD/configs/refresh_engflow_token.sh" "$TOKEN_FILE" &
REFRESHER_PID=$!
# Kill the refresher when bb_clientd exits (Ctrl-C, crash, etc.).
trap 'kill "$REFRESHER_PID" 2>/dev/null || true' EXIT INT TERM

cd "$CLIENTD"
env OS="$(uname)" HOME="$HOME" bazel run //cmd/bb_clientd -- "$CONFIG"
