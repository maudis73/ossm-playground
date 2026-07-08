#!/usr/bin/env bash
# Ingress gRPC test (Step 7). Port-forward gateway 18081:8081 first.
HOST="${1:-127.0.0.1:18081}"
echo ""
echo "Testing gRPC on gateway ${HOST} ..."
if command -v grpcurl >/dev/null 2>&1 && grpcurl -plaintext "$HOST" list >/dev/null 2>&1; then
  echo "Result: ✓ OK — gateway accepts gRPC"
  grpcurl -plaintext "$HOST" list 2>/dev/null | head -3
else
  echo "Result: ✗ FAIL — set Gateway protocol to GRPC (manifest 09)"
  command -v grpcurl >/dev/null 2>&1 || echo "(install grpcurl to test)"
fi
echo ""
