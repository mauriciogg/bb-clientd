#!/bin/bash
# Periodically mint a fresh EngFlow sc-lca-1 JWT and write it to the token file
# that bb_clientd reads (bb_clientd_engflow.jsonnet -> grpcClient files). Snap
# caps token TTL at 1h, so we re-mint well within that. bb_clientd reloads the
# file every 60s, so auth stays valid across arbitrarily long builds.
#
# Written atomically and WITHOUT a trailing newline (a stray newline is an
# invalid gRPC header value). Usage: refresh_engflow_token.sh <token-file>
set -uo pipefail

TOKEN_FILE="${1:?usage: refresh_engflow_token.sh <token-file>}"
INTERVAL="${REFRESH_INTERVAL:-1500}"   # 25 min; comfortably inside the 1h TTL
EMAIL="$(whoami)@c.snap.com"

mint() {
  # --autoRefresh keeps the underlying personal creds fresh too. The timeout
  # matters: a hung snapaccess (e.g. transient SSO/network stall) previously
  # wedged this loop silently, letting the token expire mid-build.
  timeout 60 snapaccess --email "$EMAIL" --autoRefresh jwt make --ttl=1h engflow.sc-corp.net
}

while true; do
  if tok="$(mint)" && [ -n "$tok" ]; then
    printf '%s' "$tok" > "$TOKEN_FILE.tmp" && mv -f "$TOKEN_FILE.tmp" "$TOKEN_FILE"
  else
    echo "refresh_engflow_token: failed to mint token; keeping existing $TOKEN_FILE" >&2
  fi
  sleep "$INTERVAL"
done
