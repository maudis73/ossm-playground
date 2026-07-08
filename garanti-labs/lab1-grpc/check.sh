#!/usr/bin/env bash
# Lab 1 — simple checks. Run from ossm-playground/
#
#   ./check.sh pods          → are requests spread across echo pods?
#   ./check.sh connections   → does the sidecar reuse TCP or open new ones?
#   ./check.sh errors        → are requests failing? (Step 5)
set -euo pipefail

MODE="${1:-}"
WINDOW="${2:-}"
case "$MODE" in
  pods)        WINDOW="${WINDOW:-60s}" ;;
  connections) WINDOW="${WINDOW:-30s}" ;;
  errors)      WINDOW="${WINDOW:-30s}" ;;
  *)
    echo "Usage:"
    echo "  ./garanti-labs/lab1-grpc/check.sh pods [60s]"
    echo "  ./garanti-labs/lab1-grpc/check.sh connections [30s]"
    echo "  ./garanti-labs/lab1-grpc/check.sh errors [30s]"
    exit 1
    ;;
esac

CLIENT=$(oc get pod -n ossm-playground-apps -l app=grpc-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$CLIENT" ]; then
  echo "No grpc-client pod found. Deploy Step 1 first."
  exit 1
fi

LOGS=$(oc logs -n ossm-playground-apps "$CLIENT" -c istio-proxy --since="$WINDOW" 2>/dev/null || true)
TOTAL=$(echo "$LOGS" | grep -c . || true)

if [ "$MODE" = "pods" ]; then
  PODS=$(echo "$LOGS" | awk '{
    for (i=1; i<=NF; i++) if ($i ~ /^outbound\|/) { gsub(/"/, "", $(i-1)); print $(i-1) }
  }')
  LAST8=$(echo "$PODS" | tail -8 | awk -F'[.:]' '{printf ".%s ", $(NF-1)}')
  UNIQUE=$(echo "$PODS" | sort -u | wc -l)

  echo ""
  echo "============================================================"
  echo " CHECK: Are requests spread across echo pods?"
  echo " (last ${WINDOW} of traffic)"
  echo "============================================================"
  echo ""
  echo "Last requests went to pods:${LAST8}"
  echo ""
  echo "Pods used: ${UNIQUE} (we have 3 echo replicas)"
  echo ""
  if [ "$UNIQUE" -ge 2 ] && [ "$TOTAL" -gt 15 ]; then
    echo "Result: ✓ GOOD — traffic hits more than one echo pod"
  elif [ "$UNIQUE" -le 1 ] && [ "$TOTAL" -gt 15 ]; then
    echo "Result: ✗ BAD — one pod gets everything (check port name is grpc)"
  else
    echo "Result: ? Wait longer or check the client is running"
  fi
  echo "============================================================"
  echo ""
  exit 0
fi

if [ "$MODE" = "connections" ]; then
  PORTS=$(echo "$LOGS" | awk '{
    for (i=1; i<=NF; i++) if ($i ~ /^outbound\|/) print $(i+1)
  }' | awk -F: '{print $NF}')
  LAST6=$(echo "$PORTS" | tail -6 | tr '\n' ' ')
  UNIQUE=$(echo "$PORTS" | sort -u | wc -l)

  echo ""
  echo "============================================================"
  echo " CHECK: Does the sidecar open a new TCP connection each RPC?"
  echo " (last ${WINDOW} — watch the PORT NUMBERS below)"
  echo "============================================================"
  echo ""
  echo "This is NOT the same as pod spread. For pods, run:"
  echo "  ./check.sh pods"
  echo ""
  echo "Last 6 connection ports: ${LAST6}"
  echo ""
  echo "Different ports used: ${UNIQUE} out of ${TOTAL} requests"
  echo ""
  if [ "$UNIQUE" -ge $((TOTAL - 5)) ] && [ "$TOTAL" -gt 10 ]; then
    echo "Result: NEW TCP EVERY REQUEST (high churn)"
    echo "        Normal when maxRequestsPerConnection=1."
    echo "        Pods can still be balanced → run ./check.sh pods"
  elif [ "$UNIQUE" -le 3 ] && [ "$TOTAL" -gt 10 ]; then
    echo "Result: CAPPED POOL (~1 TCP per echo pod, ~3 total)"
    echo "        Normal when tcp.maxConnections=1 and 3 replicas."
    echo "        Many RPCs still reuse those few wires → run ./check.sh pods"
  elif [ "$UNIQUE" -le 6 ] && [ "$TOTAL" -gt 10 ]; then
    echo "Result: ✓ REUSING TCP (few connections, many requests)"
  else
    echo "Result: ? Not enough traffic — wait and try again"
  fi
  echo "============================================================"
  echo ""
  exit 0
fi

# errors
ERR5=$(echo "$LOGS" | grep -cE ' 5[0-9]{2} |"5[0-9]{2}"' || true)
FLAGS=$(echo "$LOGS" | grep -cE 'UF|UO|UH' || true)

echo ""
echo "============================================================"
echo " CHECK: Are requests failing?"
echo " (last ${WINDOW})"
echo "============================================================"
echo ""
echo "Total requests: ${TOTAL}"
echo "5xx errors:     ${ERR5}"
echo "Failure flags:  ${FLAGS}"
echo ""
if [ "$ERR5" -gt 0 ] || [ "$FLAGS" -gt 5 ]; then
  echo "Result: ✗ ERRORS — pool may be too tight (http2MaxRequests?)"
else
  echo "Result: ✓ OK — no obvious errors"
fi
echo "============================================================"
echo ""
