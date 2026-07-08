#!/usr/bin/env bash
# Deprecated — use check.sh
DIR="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  --spread) exec "$DIR/check.sh" pods "${2:-60s}" ;;
  --errors) exec "$DIR/check.sh" errors "${2:-30s}" ;;
  *)        exec "$DIR/check.sh" connections "${1:-30s}" ;;
esac
