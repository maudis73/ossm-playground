#!/usr/bin/env bash
# Live view: each gRPC request → which echo pod handled it.
# Run from ossm-playground/  Ctrl+C to stop.
#
# Example output:
#   [2026-07-07T08:00:01.123Z] "POST -> 10.128.0.85:8079
set -euo pipefail

NS="${NAMESPACE:-ossm-playground-apps}"
CLIENT=$(oc get pod -n "$NS" -l app=grpc-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$CLIENT" ]; then
  echo "No grpc-client pod in ${NS}. Deploy Lab 1 Step 1 first."
  exit 1
fi

echo "Watching grpc-client/${CLIENT} istio-proxy — each line = one request → echo pod"
echo "Look for different .85 .86 .87 addresses (3 echo replicas)"
echo ""

oc logs -n "$NS" -f --tail=0 "$CLIENT" -c istio-proxy 2>/dev/null | awk '
  /outbound\|/ {
    for (i = 1; i <= NF; i++)
      if ($i ~ /outbound\|/) {
        gsub(/"/, "", $(i-1))
        print $1, $2, $3, "->", $(i-1)
        fflush()
      }
  }
'
