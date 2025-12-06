#!/bin/bash
set -euo pipefail

# Load env safely (ENV_FILE -> ./ .env -> /opt/.env)
ENV_LOC=""
if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE:-}" ]]; then
  ENV_LOC="${ENV_FILE:-}"
elif [[ -f .env ]]; then
  ENV_LOC=".env"
elif [[ -f /opt/.env ]]; then
  ENV_LOC="/opt/.env"
fi

if [[ -n "$ENV_LOC" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_LOC"
  set +a
else
  echo "❌ .env file not found (tried: ENV_FILE, ./ .env, /opt/.env)"
  exit 1
fi

# Required config
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-}"
PURGE_CHANNEL_ID="${PURGE_CHANNEL_ID:-}"
PURGE_PREFIX="${PURGE_PREFIX:-**Balance Report for }"
SCAN_LIMIT=${SCAN_LIMIT:-200}
LOG_FILE="${PURGE_LOG_FILE:-/var/log/discord_purge.log}"

if [[ -z "$DISCORD_BOT_TOKEN" || -z "$PURGE_CHANNEL_ID" ]]; then
  echo "❌ DISCORD_BOT_TOKEN and PURGE_CHANNEL_ID must be set in env"
  exit 1
fi

API_BASE="https://discord.com/api/v10"
AUTH_HEADER=( -H "Authorization: Bot $DISCORD_BOT_TOKEN" -H "User-Agent: discord-purge-script" )

# Logging helper
log(){
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# HTTP GET with exponential backoff handling 429
http_get_with_backoff(){
  local url="$1"
  local retries=0
  local max_retries=6
  local backoff=1
  local headers tmp_body tmp_headers http_status

  while true; do
    tmp_headers=$(mktemp)
    tmp_body=$(mktemp)
    http_status=$(curl -s -D "$tmp_headers" -o "$tmp_body" -w '%{http_code}' "${AUTH_HEADER[@]}" "$url" || echo "000")
    if [ "$http_status" == "429" ]; then
      # read Retry-After
      retry_after=$(grep -i '^Retry-After:' "$tmp_headers" | awk '{print $2}' | tr -d '\r' || true)
      if [[ -n "$retry_after" ]]; then
        sleep_time=$retry_after
      else
        sleep_time=$backoff
        backoff=$((backoff*2))
        if [ $backoff -gt 60 ]; then backoff=60; fi
      fi
      log "Received 429; sleeping for $sleep_time seconds (attempt $((retries+1)))"
      sleep "$sleep_time"
      retries=$((retries+1))
      rm -f "$tmp_headers" "$tmp_body"
      if [ $retries -ge $max_retries ]; then
        log "Max retries reached for GET $url"
        return 1
      fi
      continue
    fi

    if [ "$http_status" != "200" ]; then
      log "Unexpected HTTP $http_status for GET $url"
      cat "$tmp_body" 2>/dev/null | sed -n '1,200p' >> "$LOG_FILE"
      rm -f "$tmp_headers" "$tmp_body"
      return 1
    fi

    # success: print body to stdout
    cat "$tmp_body"
    rm -f "$tmp_headers" "$tmp_body"
    return 0
  done
}

# HTTP DELETE with retries and exponential backoff (handles 429/5xx)
http_delete_with_backoff(){
  local url="$1"
  local retries=0
  local max_retries=6
  local backoff=1
  local tmp_headers http_status retry_after

  while true; do
    tmp_headers=$(mktemp)
    http_status=$(curl -s -D "$tmp_headers" -o /dev/null -w '%{http_code}' -X DELETE "${AUTH_HEADER[@]}" "$url" || echo "000")

    if [ "$http_status" == "429" ]; then
      retry_after=$(grep -i '^Retry-After:' "$tmp_headers" | awk '{print $2}' | tr -d '\r' || true)
      if [[ -n "$retry_after" ]]; then
        sleep_time=$retry_after
      else
        sleep_time=$backoff
        backoff=$((backoff*2))
        if [ $backoff -gt 60 ]; then backoff=60; fi
      fi
      log "Received 429 for DELETE $url; sleeping $sleep_time (attempt $((retries+1)))"
      sleep "$sleep_time"
      retries=$((retries+1))
      rm -f "$tmp_headers"
      if [ $retries -ge $max_retries ]; then
        log "Max retries reached for DELETE $url (last status $http_status)"
        return 1
      fi
      continue
    fi

    if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
      rm -f "$tmp_headers"
      return 0
    fi

    # retry on server errors
    if [ "$http_status" -ge 500 ] && [ $retries -lt $max_retries ]; then
      log "Server error $http_status for DELETE $url; backing off $backoff seconds"
      sleep $backoff
      backoff=$((backoff*2))
      if [ $backoff -gt 60 ]; then backoff=60; fi
      retries=$((retries+1))
      rm -f "$tmp_headers"
      continue
    fi

    log "Failed DELETE $url with status $http_status"
    rm -f "$tmp_headers"
    return 1
  done
}

# Main: fetch messages and collect IDs to delete
log "Starting discord purge scan (limit=$SCAN_LIMIT)"
fetched=0
after=""
ids_to_delete=()

# Notification webhook (optional) — send start/finish notifications
PURGE_WEBHOOK_URL="${PURGE_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"
send_webhook(){
  local msg="$1"
  if [[ -z "${PURGE_WEBHOOK_URL:-}" ]]; then
    return 0
  fi
  now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
  payload=$(jq -n --arg content "[$now_ts] $msg" '{content:$content}')
  curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$PURGE_WEBHOOK_URL" >/dev/null || true
}

# Notify start
send_webhook "Purge scan started (limit=$SCAN_LIMIT)"

while [ $fetched -lt $SCAN_LIMIT ]; do
  limit=100
  remaining=$((SCAN_LIMIT - fetched))
  if [ $remaining -lt $limit ]; then
    limit=$remaining
  fi
  url="$API_BASE/channels/$PURGE_CHANNEL_ID/messages?limit=$limit"
  if [[ -n "$after" ]]; then
    url+="&after=$after"
  fi

  resp=$(http_get_with_backoff "$url") || break

  msgs_count=$(echo "$resp" | jq 'length')
  if [ "$msgs_count" -eq 0 ]; then
    break
  fi

  matches=$(echo "$resp" | jq -r --arg prefix "$PURGE_PREFIX" '.[] | select(.content|startswith($prefix)) | .id') || true
  if [[ -n "$matches" ]]; then
    while IFS= read -r mid; do
      if [[ -n "$mid" ]]; then
        ids_to_delete+=("$mid")
      fi
    done <<< "$matches"
  fi

  last_id=$(echo "$resp" | jq -r '.[-1].id') || true
  if [[ -z "$last_id" || "$last_id" == "null" ]]; then
    break
  fi
  after="$last_id"
  fetched=$((fetched + msgs_count))
  sleep 0.5
done

log "Found ${#ids_to_delete[@]} messages to delete"
if [ ${#ids_to_delete[@]} -eq 0 ]; then
  log "No messages to purge found. Exiting."
  exit 0
fi

for mid in "${ids_to_delete[@]}"; do
  del_url="$API_BASE/channels/$PURGE_CHANNEL_ID/messages/$mid"
  log "Deleting message $mid"
  if http_delete_with_backoff "$del_url"; then
    log "Deleted $mid"
  else
    log "Failed to delete $mid after retries"
  fi
  sleep 0.5
done

log "Purge completed"
send_webhook "Purge completed. Deleted ${#ids_to_delete[@]} messages."
exit 0
