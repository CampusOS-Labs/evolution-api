#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PID_FILE="${EVOLUTION_PID_FILE:-/tmp/evolution-api.pid}"
WITH_SERVICES=false

usage() {
  cat <<'EOF'
Usage: ./bulk-sender/stop-evolution.sh [--with-services]

Options:
  --with-services   Also stop helper Postgres and Redis docker compose stacks
  -h, --help        Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-services)
      WITH_SERVICES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }

if [[ -f "$PID_FILE" ]]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "$PID" ]] && kill -0 "$PID" >/dev/null 2>&1; then
    log "Stopping Evolution API process ${PID}"
    kill "$PID" >/dev/null 2>&1 || true
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

if pgrep -af "tsx watch ./src/main.ts" >/dev/null 2>&1; then
  log "Stopping remaining dev server processes"
  pkill -f "tsx watch ./src/main.ts" || true
fi

if [[ "$WITH_SERVICES" == "true" ]]; then
  log "Stopping docker helper services"
  docker compose -f "$ROOT_DIR/Docker/postgres/docker-compose.yaml" down || true
  docker compose -f "$ROOT_DIR/Docker/redis/docker-compose.yaml" down || true
fi

log "Done"
