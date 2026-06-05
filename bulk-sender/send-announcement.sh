#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
INSTANCE="${INSTANCE:-evolution}"
API_KEY="${API_KEY:-429683C4C977415CAAFCCE10F7D57E11}"

MIN_DELAY_MS="${MIN_DELAY_MS:-4000}"
MAX_DELAY_MS="${MAX_DELAY_MS:-9000}"
TIMEOUT_S="${TIMEOUT_S:-30}"

MESSAGE="${MESSAGE:-This is principal manjul sher and this is a reminder from the school: Kidzee that your school fee still remais unpaid}"

# 4 contacts (E.164 with country code, no +)
CONTACTS=(
  "919970708106"
  "917038667755"
  "918459058981"
  "15137997001"
)

log() { printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"; }

random_delay_ms() {
  local min="$1" max="$2"
  echo $(( min + RANDOM % (max - min + 1) ))
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }
}

require_cmd curl
require_cmd jq

log "Checking instance state: $INSTANCE"
STATE=$(curl -sS --max-time "$TIMEOUT_S" \
  -H "apikey: $API_KEY" \
  "$BASE_URL/instance/connectionState/$INSTANCE" | jq -r '.instance.state // "unknown"')

log "Instance state: $STATE"
if [[ "$STATE" != "open" ]]; then
  log "ERROR: instance is not open. Scan the QR and try again."
  exit 2
fi

log "Validating ${#CONTACTS[@]} contacts"
VALID_BODY=$(jq -nc --argjson n "${#CONTACTS[@]}" \
  '{numbers: $ARGS.positional}' --args "${CONTACTS[@]}")
VALID=$(curl -sS --max-time "$TIMEOUT_S" \
  -X POST \
  -H "Content-Type: application/json" \
  -H "apikey: $API_KEY" \
  -d "$VALID_BODY" \
  "$BASE_URL/chat/whatsappNumbers/$INSTANCE")

log "Validation result:"
echo "$VALID" | jq .

VALID_NUMBERS=()
while IFS=$'\t' read -r number exists; do
  if [[ "$exists" == "true" ]]; then
    VALID_NUMBERS+=("$number")
  fi
done < <(echo "$VALID" | jq -r '.[] | [.number, (.exists|tostring)] | @tsv')

if [[ ${#VALID_NUMBERS[@]} -eq 0 ]]; then
  log "No valid contacts to send to. Exiting."
  exit 0
fi

log "Sending to ${#VALID_NUMBERS[@]} valid contact(s)"
SENT=0
FAILED=0

for number in "${VALID_NUMBERS[@]}"; do
  log "Sending -> $number"
  RESP=$(curl -sS --max-time "$TIMEOUT_S" \
    -w "\n%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "apikey: $API_KEY" \
    -d "$(jq -nc --arg n "$number" --arg t "$MESSAGE" '{number:$n, text:$t}')" \
    "$BASE_URL/message/sendText/$INSTANCE" || true)

  CODE=$(printf "%s" "$RESP" | tail -n1)
  BODY=$(printf "%s" "$RESP" | sed '$d')

  if [[ "$CODE" == "201" || "$CODE" == "200" ]]; then
    MSG_ID=$(echo "$BODY" | jq -r '.key.id // empty' 2>/dev/null || true)
    log "SENT $number (id=$MSG_ID)"
    SENT=$((SENT+1))
  else
    log "FAILED $number (http=$CODE) body=$BODY"
    FAILED=$((FAILED+1))
  fi

  if [[ "$number" != "${VALID_NUMBERS[-1]}" ]]; then
    WAIT=$(random_delay_ms "$MIN_DELAY_MS" "$MAX_DELAY_MS")
    log "Sleeping ${WAIT}ms before next send"
    sleep "$(awk -v ms="$WAIT" 'BEGIN{print ms/1000}')"
  fi
done

log "Done. Sent: $SENT, Failed: $FAILED"
