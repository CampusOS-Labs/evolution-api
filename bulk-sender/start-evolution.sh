#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="${EVOLUTION_LOG_FILE:-/tmp/evolution-api.log}"
PID_FILE="${EVOLUTION_PID_FILE:-/tmp/evolution-api.pid}"

BASE_URL="${BASE_URL:-http://localhost:8080}"
INSTANCE_NAME="${INSTANCE_NAME:-evolution}"

DATABASE_PROVIDER="${DATABASE_PROVIDER:-postgresql}"
DATABASE_CONNECTION_URI="${DATABASE_CONNECTION_URI:-postgresql://opencut:opencut@localhost:5432/opencut?schema=evolution_api}"
CACHE_REDIS_URI="${CACHE_REDIS_URI:-redis://localhost:6379/6}"

PG_HOST="${PG_HOST:-localhost}"
PG_PORT="${PG_PORT:-5432}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"

PG_CONTAINER="${PG_CONTAINER:-opencut-db-1}"
NO_DOCKER="${NO_DOCKER:-false}"
SKIP_INSTALL="${SKIP_INSTALL:-false}"
FOREGROUND="${FOREGROUND:-false}"

usage() {
  cat <<'EOF'
Usage: ./bulk-sender/start-evolution.sh [options]

Options:
  --foreground     Run API in foreground (stream logs)
  --skip-install   Skip npm install even when node_modules is missing
  --no-docker      Do not auto-start docker postgres/redis if ports are down
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreground)
      FOREGROUND=true
      shift
      ;;
    --skip-install)
      SKIP_INSTALL=true
      shift
      ;;
    --no-docker)
      NO_DOCKER=true
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
fail() { log "ERROR: $*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"
}

is_port_open() {
  local host="$1"
  local port="$2"
  (echo >"/dev/tcp/${host}/${port}") >/dev/null 2>&1
}

wait_for_port() {
  local host="$1"
  local port="$2"
  local label="$3"
  local timeout_s="${4:-30}"
  local elapsed=0

  while ! is_port_open "$host" "$port"; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [[ "$elapsed" -ge "$timeout_s" ]]; then
      fail "Timeout waiting for ${label} on ${host}:${port}"
    fi
  done
}

load_or_create_env() {
  if [[ ! -f "$ROOT_DIR/.env" ]]; then
    log ".env not found. Creating from .env.example"
    cp "$ROOT_DIR/.env.example" "$ROOT_DIR/.env"
  fi
}

read_api_key() {
  if [[ -f "$ROOT_DIR/.env" ]]; then
    grep -E '^AUTHENTICATION_API_KEY=' "$ROOT_DIR/.env" | head -n1 | cut -d'=' -f2-
  fi
}

start_support_services() {
  if is_port_open "$PG_HOST" "$PG_PORT"; then
    log "Postgres already reachable at ${PG_HOST}:${PG_PORT}"
  else
    [[ "$NO_DOCKER" == "true" ]] && fail "Postgres not reachable and --no-docker is set"
    log "Starting Postgres via docker compose"
    if ! docker compose -f "$ROOT_DIR/Docker/postgres/docker-compose.yaml" up -d; then
      log "Postgres compose returned non-zero, re-checking port"
    fi
    wait_for_port "$PG_HOST" "$PG_PORT" "Postgres" 45
  fi

  if is_port_open "$REDIS_HOST" "$REDIS_PORT"; then
    log "Redis already reachable at ${REDIS_HOST}:${REDIS_PORT}"
  else
    [[ "$NO_DOCKER" == "true" ]] && fail "Redis not reachable and --no-docker is set"
    log "Starting Redis via docker compose"
    if ! docker compose -f "$ROOT_DIR/Docker/redis/docker-compose.yaml" up -d; then
      log "Redis compose returned non-zero, re-checking port"
    fi
    wait_for_port "$REDIS_HOST" "$REDIS_PORT" "Redis" 30
  fi
}

ensure_schema_best_effort() {
  local schema_name="evolution_api"
  if [[ "$DATABASE_CONNECTION_URI" == *"schema="* ]]; then
    schema_name="${DATABASE_CONNECTION_URI##*schema=}"
    schema_name="${schema_name%%&*}"
  fi

  if docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
    local pg_user pg_db
    pg_user="$(docker inspect "$PG_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_USER=' | cut -d= -f2 | head -n1 || true)"
    pg_db="$(docker inspect "$PG_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep '^POSTGRES_DB=' | cut -d= -f2 | head -n1 || true)"

    pg_user="${pg_user:-opencut}"
    pg_db="${pg_db:-opencut}"

    log "Ensuring schema '${schema_name}' exists in container ${PG_CONTAINER}"
    if ! docker exec "$PG_CONTAINER" psql -U "$pg_user" -d "$pg_db" -c "CREATE SCHEMA IF NOT EXISTS \"${schema_name}\";" >/dev/null; then
      log "Schema create skipped (non-fatal)"
    fi
  else
    log "Postgres container ${PG_CONTAINER} not found, skipping schema bootstrap"
  fi
}

install_and_migrate() {
  if [[ ! -d "$ROOT_DIR/node_modules" && "$SKIP_INSTALL" != "true" ]]; then
    log "Installing npm dependencies"
    (cd "$ROOT_DIR" && npm install)
  elif [[ ! -d "$ROOT_DIR/node_modules" && "$SKIP_INSTALL" == "true" ]]; then
    fail "node_modules missing and --skip-install set"
  else
    log "node_modules already present"
  fi

  log "Generating Prisma client"
  (cd "$ROOT_DIR" && DATABASE_PROVIDER="$DATABASE_PROVIDER" DATABASE_CONNECTION_URI="$DATABASE_CONNECTION_URI" npm run db:generate)

  log "Deploying Prisma migrations"
  (cd "$ROOT_DIR" && DATABASE_PROVIDER="$DATABASE_PROVIDER" DATABASE_CONNECTION_URI="$DATABASE_CONNECTION_URI" npm run db:deploy)
}

api_is_healthy() {
  curl -fsS --max-time 3 "$BASE_URL/" >/dev/null 2>&1
}

wait_for_api() {
  local timeout_s="${1:-60}"
  local elapsed=0

  while ! api_is_healthy; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [[ "$elapsed" -ge "$timeout_s" ]]; then
      log "API failed to become healthy. Last logs:"
      tail -n 80 "$LOG_FILE" || true
      fail "Evolution API did not start on ${BASE_URL}"
    fi
  done
}

start_api() {
  if api_is_healthy; then
    log "Evolution API already responding at ${BASE_URL}"
    return
  fi

  if [[ -f "$PID_FILE" ]]; then
    local old_pid
    old_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
      log "Stopping stale process from pid file (${old_pid})"
      kill "$old_pid" >/dev/null 2>&1 || true
      sleep 1
    fi
    rm -f "$PID_FILE"
  fi

  if [[ "$FOREGROUND" == "true" ]]; then
    log "Starting Evolution API in foreground"
    cd "$ROOT_DIR"
    DATABASE_PROVIDER="$DATABASE_PROVIDER" \
    DATABASE_CONNECTION_URI="$DATABASE_CONNECTION_URI" \
    CACHE_REDIS_URI="$CACHE_REDIS_URI" \
    npm run dev:server
    return
  fi

  log "Starting Evolution API in background"
  (
    cd "$ROOT_DIR"
    nohup env \
      DATABASE_PROVIDER="$DATABASE_PROVIDER" \
      DATABASE_CONNECTION_URI="$DATABASE_CONNECTION_URI" \
      CACHE_REDIS_URI="$CACHE_REDIS_URI" \
      npm run dev:server >"$LOG_FILE" 2>&1 &
    echo $! >"$PID_FILE"
  )

  wait_for_api 60
}

print_summary() {
  local api_key
  api_key="$(read_api_key)"

  log "Evolution API is ready"
  echo
  echo "Base URL:      ${BASE_URL}"
  echo "Instance name: ${INSTANCE_NAME}"
  [[ -n "$api_key" ]] && echo "API Key:       ${api_key}"
  echo "Logs:          ${LOG_FILE}"
  [[ -f "$PID_FILE" ]] && echo "PID file:      ${PID_FILE}"
  echo
  echo "Quick checks:"
  echo "  curl ${BASE_URL}/"
  [[ -n "$api_key" ]] && echo "  curl -H \"apikey: ${api_key}\" ${BASE_URL}/instance/connectionState/${INSTANCE_NAME}"
  echo
  echo "If instance is not open yet:"
  [[ -n "$api_key" ]] && echo "  curl -H \"apikey: ${api_key}\" ${BASE_URL}/instance/connect/${INSTANCE_NAME}"
}

main() {
  require_cmd bash
  require_cmd curl
  require_cmd docker
  require_cmd npm
  require_cmd npx

  load_or_create_env
  start_support_services
  ensure_schema_best_effort
  install_and_migrate
  start_api
  print_summary
}

main "$@"
