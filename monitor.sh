#!/bin/bash
set -eo pipefail

# If this script was invoked via /bin/sh (cron may do this), re-exec under bash
if [ -z "${BASH_VERSION:-}" ]; then
    exec /bin/bash "$0" "$@"
fi

# Load .env file safely
ENV_LOC=""
if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE:-}" ]]; then
    ENV_LOC="$ENV_FILE"
elif [[ -f .env ]]; then
    ENV_LOC=".env"
elif [[ -f /opt/.env ]]; then
    ENV_LOC="/opt/.env"
fi

if [[ -n "$ENV_LOC" ]]; then
    echo "🔐 Loading env from $ENV_LOC"
    echo "📄 File contents (first 10 lines, sanitized):"
    head -n 10 "$ENV_LOC" | sed 's/=.*/=***/' || echo "  (could not read file)"
    echo ""
    
    set -a
    # shellcheck disable=SC1090
    source "$ENV_LOC"
    set +a
    
    echo "✅ Environment file sourced"
else
    echo "❌ .env file not found (tried: ENV_FILE, ./.env, /opt/.env)"
    exit 1
fi

# Read required variables
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
RESULTS_API_URL="${RESULTS_API_URL:-}"
AUTH_PASS="${AUTH_PASS:-}"
BASE_URL="${BASE_URL:-}"
QUEUE_TIMEOUT_URL="${QUEUE_TIMEOUT_URL:-}"
RESULT_URL="${RESULT_URL:-}"
VPN_ORG_KEYWORD="${VPN_ORG_KEYWORD:-Proton}"

echo ""
echo "🔍 Checking loaded environment variables:"
echo "  DISCORD_WEBHOOK_URL: ${DISCORD_WEBHOOK_URL:+SET (${#DISCORD_WEBHOOK_URL} chars)}${DISCORD_WEBHOOK_URL:-NOT SET}"
echo "  RESULTS_API_URL: ${RESULTS_API_URL:+SET (${#RESULTS_API_URL} chars)}${RESULTS_API_URL:-NOT SET}"
echo "  AUTH_PASS: ${AUTH_PASS:+SET (${#AUTH_PASS} chars)}${AUTH_PASS:-NOT SET}"
echo "  BASE_URL: ${BASE_URL:+SET (${#BASE_URL} chars)}${BASE_URL:-NOT SET}"
echo "  QUEUE_TIMEOUT_URL: ${QUEUE_TIMEOUT_URL:+SET (${#QUEUE_TIMEOUT_URL} chars)}${QUEUE_TIMEOUT_URL:-NOT SET}"
echo "  RESULT_URL: ${RESULT_URL:+SET (${#RESULT_URL} chars)}${RESULT_URL:-NOT SET}"
echo ""

# Validate required env vars
if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    echo "❌ DISCORD_WEBHOOK_URL not set in .env"
    exit 1
fi
if [[ -z "$RESULTS_API_URL" ]]; then
    echo "❌ RESULTS_API_URL not set in .env"
    exit 1
fi
if [[ -z "$AUTH_PASS" ]]; then
    echo "❌ AUTH_PASS not set in .env"
    exit 1
fi
if [[ -z "$BASE_URL" ]]; then
    echo "❌ BASE_URL not set in .env (M-Pesa API base URL)"
    echo ""
    echo "💡 Your .env file should contain:"
    echo "   BASE_URL=https://sandbox.safaricom.co.ke"
    echo "   or"
    echo "   BASE_URL=https://api.safaricom.co.ke"
    exit 1
fi
if [[ -z "$QUEUE_TIMEOUT_URL" ]]; then
    echo "❌ QUEUE_TIMEOUT_URL not set in .env"
    exit 1
fi
if [[ -z "$RESULT_URL" ]]; then
    echo "❌ RESULT_URL not set in .env"
    exit 1
fi

echo "✅ All required environment variables loaded"
echo ""

# Helper: send alert to Discord webhook
send_discord_alert() {
    local title="$1"
    local body="$2"
    local payload
    now_ts=$(date '+%Y-%m-%d %H:%M:%S %Z')
    payload=$(jq -n --arg content "[$now_ts] **$title**\n\n$body" '{content:$content}')
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$DISCORD_WEBHOOK_URL" >/dev/null || true
}

# VPN check
PUBLIC_IP=$(curl -s https://ipinfo.io/ip || echo "unknown")
IP_JSON=$(curl -s https://ipinfo.io/json || echo "{}")

if ip a show tun0 &>/dev/null; then
    ROUTE_INFO=$(ip route get 8.8.8.8 2>/dev/null || true)
    if echo "$ROUTE_INFO" | grep -q "dev tun0"; then
        echo "✅ VPN detected: tun0 present and route for external traffic uses tun0"
    else
        DEFDEV=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || true)
        if [[ "$DEFDEV" == "tun0" ]]; then
            echo "✅ VPN detected: tun0 present and default route uses tun0"
        else
            echo "❌ tun0 present but default route does not use tun0 (dev=$DEFDEV)"
            MSG_BODY="- Public IP: \`$PUBLIC_IP\`\n- Route info: \`$ROUTE_INFO\`\n\nFull ipinfo:\n\n\`\`\`\n$IP_JSON\n\`\`\`"
            send_discord_alert "ALERT: VPN route mismatch" "$MSG_BODY"
            exit 1
        fi
    fi
else
    echo "❌ No VPN tunnel (tun0) detected"
    MSG_BODY="- Public IP: \`$PUBLIC_IP\`\n\nFull ipinfo:\n\n\`\`\`\n$IP_JSON\n\`\`\`"
    send_discord_alert "ALERT: No VPN tunnel detected" "$MSG_BODY"
    exit 1
fi

# Prepare CSV file
echo "Shortcode,OriginatorConversationID,ConversationID,Balance" > results.csv

# Step 1: Send AccountBalance requests
declare -A ORIGINATOR_MAP
INDEX=1
MAX_ACCOUNTS=20
REQUESTS_SENT=0
SKIPPED_ACCOUNTS=0

echo ""
echo "==== STEP 1: Sending Balance Requests ===="
echo "🔍 Scanning for account configurations (indices 1-$MAX_ACCOUNTS)..."
echo ""

while [[ $INDEX -le $MAX_ACCOUNTS ]]; do
    CK_VAR="CONSUMER_KEY_${INDEX}"
    CS_VAR="CONSUMER_SECRET_${INDEX}"
    SHORTCODE_VAR="SHORTCODE_${INDEX}"
    INITIATOR_VAR="INITIATOR_${INDEX}"
    SECURITY_CREDENTIAL_VAR="SECURITY_CREDENTIAL_${INDEX}"
    
    CONSUMER_KEY="${!CK_VAR}"
    CONSUMER_SECRET="${!CS_VAR}"
    SHORTCODE="${!SHORTCODE_VAR}"
    INITIATOR="${!INITIATOR_VAR}"
    SECURITY_CREDENTIAL="${!SECURITY_CREDENTIAL_VAR}"
    
    echo "🔎 Checking index $INDEX: SHORTCODE_${INDEX} = ${SHORTCODE:-NOT SET}"
    
    # Skip commented/missing accounts
    if [[ -z "$SHORTCODE" ]]; then
        echo "  ⏭️  Skipping index $INDEX (commented out or not configured)"
        SKIPPED_ACCOUNTS=$((SKIPPED_ACCOUNTS + 1))
        INDEX=$((INDEX + 1))
        continue
    fi
    
    echo ""
    echo "► Sending request for shortcode: $SHORTCODE (Index $INDEX)"
    echo "  📡 Fetching OAuth token from: $BASE_URL/oauth/v1/generate"
    
    ACCESS_TOKEN=$(curl -s -u "$CONSUMER_KEY:$CONSUMER_SECRET" \
        "$BASE_URL/oauth/v1/generate?grant_type=client_credentials" | jq -r '.access_token')
    
    if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
        echo "  ❌ Failed to fetch access token"
        echo "  💡 Check CONSUMER_KEY_${INDEX} and CONSUMER_SECRET_${INDEX} in .env"
        INDEX=$((INDEX + 1))
        continue
    fi
    
    echo "  ✅ Access token retrieved (${#ACCESS_TOKEN} chars)"
    echo "  📡 Sending balance request to: $BASE_URL/mpesa/accountbalance/v1/query"
    
    RESPONSE=$(curl -s -X POST "$BASE_URL/mpesa/accountbalance/v1/query" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
            \"Initiator\": \"$INITIATOR\",
            \"SecurityCredential\": \"$SECURITY_CREDENTIAL\",
            \"CommandID\": \"AccountBalance\",
            \"PartyA\": \"$SHORTCODE\",
            \"IdentifierType\": \"4\",
            \"Remarks\": \"Balance Query\",
            \"QueueTimeOutURL\": \"$QUEUE_TIMEOUT_URL\",
            \"ResultURL\": \"$RESULT_URL\"
        }")
    
    echo "  📥 Response received (${#RESPONSE} chars)"
    
    ORIGINATOR_CONVERSATION_ID=$(echo "$RESPONSE" | jq -r '.OriginatorConversationID')
    
    if [[ -z "$ORIGINATOR_CONVERSATION_ID" || "$ORIGINATOR_CONVERSATION_ID" == "null" ]]; then
        echo "  ❌ Failed to extract OriginatorConversationID"
        echo "  📄 Response: $RESPONSE"
        INDEX=$((INDEX + 1))
        continue
    fi
    
    echo "  ✅ OriginatorConversationID: $ORIGINATOR_CONVERSATION_ID"
    ORIGINATOR_MAP["$ORIGINATOR_CONVERSATION_ID"]="$SHORTCODE"
    REQUESTS_SENT=$((REQUESTS_SENT + 1))
    INDEX=$((INDEX + 1))
done

echo ""
echo "📍 Finished scanning all $MAX_ACCOUNTS account slots"

echo ""
echo "==== STEP 1 SUMMARY ===="
echo "✅ Requests sent: $REQUESTS_SENT"
echo "⏭️  Accounts skipped (commented/missing): $SKIPPED_ACCOUNTS"

if [[ $REQUESTS_SENT -eq 0 ]]; then
    echo ""
    echo "❌ No requests were sent. Please check your .env configuration."
    exit 1
fi

# Step 2: Wait for callbacks
WAIT_SECONDS=10
echo ""
echo "⏳ Waiting $WAIT_SECONDS seconds for M-Pesa callbacks..."
sleep $WAIT_SECONDS

# Step 3: Fetch results
echo ""
echo "==== STEP 2: Fetching Results from API ===="
RESULT_JSON=$(curl -s -H "auth: $AUTH_PASS" "$RESULTS_API_URL")

# Step 4: Process results
echo ""
echo "==== STEP 3: Processing Results ===="
PROCESSED_COUNT=0
MISSING_COUNT=0

for CID in "${!ORIGINATOR_MAP[@]}"; do
    SHORTCODE="${ORIGINATOR_MAP[$CID]}"
    echo ""
    echo "► Processing: $SHORTCODE (CID: $CID)"
    
    # Normalize .text field
    MATCH_OBJ=$(echo "$RESULT_JSON" | jq -c --arg cid "$CID" '
        .data[] |
        .text as $t |
        (if ($t | type) == "string" then ($t | fromjson) else $t end) as $obj |
        select($obj.Result.OriginatorConversationID == $cid) |
        $obj')
    
    if [[ -z "$MATCH_OBJ" || "$MATCH_OBJ" == "null" ]]; then
        echo "  ❌ No callback found"
        MISSING_COUNT=$((MISSING_COUNT + 1))
        continue
    fi
    
    PARSED="$MATCH_OBJ"
    CONVERSATION_ID=$(echo "$PARSED" | jq -r '.Result.ConversationID')
    ACCOUNT_BALANCE=$(echo "$PARSED" | jq -r '.Result.ResultParameters.ResultParameter[] | select(.Key=="AccountBalance") | .Value')
    
    echo "  ✅ ConversationID: $CONVERSATION_ID"
    echo "  ✅ Balance: $ACCOUNT_BALANCE"
    
    # Save to CSV
    echo "$SHORTCODE,$CID,$CONVERSATION_ID,\"$ACCOUNT_BALANCE\"" >> results.csv
    
    # Format and send to Discord
    RAW_BAL="$ACCOUNT_BALANCE"
    CLEAN_BAL=$(echo "$RAW_BAL" | tr '|;' '&')
    
    IFS='&' read -ra TOKS <<< "$CLEAN_BAL"
    
    trim() { echo "${1}" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }
    
    FORM_LINES=()
    total=${#TOKS[@]}
    idx=0
    
    while [ $idx -lt $total ]; do
        t=$(trim "${TOKS[$idx]}")
        t=$(echo "$t" | sed -E 's/^\"|\"$//g')
        
        if echo "$t" | grep -q ':'; then
            FORM_LINES+=("$t")
            idx=$((idx+1))
            continue
        fi
        
        if echo "$t" | grep -qiE 'account|charge|balance|utility|working|merchant|loan|savings|deduction'; then
            found=""
            consume=1
            j=$((idx+1))
            
            while [ $j -lt $total ] && [ $j -le $((idx+5)) ]; do
                cand=$(trim "${TOKS[$j]}")
                cand=$(echo "$cand" | sed -E 's/^\"|\"$//g')
                
                if echo "$cand" | grep -qE '^[A-Z]{2,4}$|^KES$'; then
                    consume=$((consume+1))
                    j=$((j+1))
                    continue
                fi
                
                if [[ "$cand" =~ ^[0-9]+([.,][0-9]+)*$ ]]; then
                    found="$cand"
                    break
                fi
                break
            done
            
            if [ -n "$found" ]; then
                FORM_LINES+=("$t: $found")
                pos=$j
                skip_count=$((pos - idx + 1))
                idx=$((idx + skip_count))
                continue
            else
                FORM_LINES+=("$t")
                idx=$((idx+1))
                continue
            fi
        fi
        
        if [[ "$t" =~ ^[0-9]+([.,][0-9]+)*$ ]]; then
            next=$((idx+1))
            if [ $next -lt $total ]; then
                nxt=$(trim "${TOKS[$next]}")
                nxt=$(echo "$nxt" | sed -E 's/^\"|\"$//g')
                if echo "$nxt" | grep -qiE 'account|utility|charge|balance|working|merchant|loan|savings|deduction'; then
                    FORM_LINES+=("$nxt: $t")
                    idx=$((idx+2))
                    continue
                fi
            fi
            FORM_LINES+=("$t")
            idx=$((idx+1))
            continue
        fi
        
        if [ -n "$t" ]; then
            FORM_LINES+=("$t")
        fi
        idx=$((idx+1))
    done
    
    # Clean up formatted lines
    if [ ${#FORM_LINES[@]} -eq 0 ]; then
        FORMATTED_BAL="$RAW_BAL"
    else
        CLEANED_LINES=()
        for ln in "${FORM_LINES[@]}"; do
            ln_trim=$(echo "$ln" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
            
            if [[ -z "$ln_trim" ]]; then
                continue
            fi
            
            if [[ "$(echo "$ln_trim" | tr '[:upper:]' '[:lower:]')" == "no" ]]; then
                continue
            fi
            
            if echo "$ln_trim" | grep -qE '^([A-Z]{2,4}|KES)$'; then
                continue
            fi
            
            if [[ "$ln_trim" =~ ^[0-9]+([.,][0-9]+)*$ ]]; then
                prev=""
                if [ ${#CLEANED_LINES[@]} -gt 0 ]; then
                    prev="${CLEANED_LINES[-1]}"
                fi
                if [[ -n "$prev" && "$prev" == *"$ln_trim"* ]]; then
                    continue
                fi
            fi
            
            if [ ${#CLEANED_LINES[@]} -gt 0 ]; then
                if [[ "${CLEANED_LINES[-1]}" == "$ln_trim" ]]; then
                    continue
                fi
            fi
            
            CLEANED_LINES+=("$ln_trim")
        done
        
        FORMATTED_BAL=""
        for ln in "${CLEANED_LINES[@]}"; do
            if [[ -n "$FORMATTED_BAL" ]]; then
                FORMATTED_BAL+=$'\n'
            fi
            FORMATTED_BAL+="$ln"
        done
    fi
    
    # Send to Discord
    MSG_HEADER="**Balance Report for $SHORTCODE**"
    MSG_CONV="- ConversationID: \`$CONVERSATION_ID\`"
    MSG_IP="- Queried from IP: \`$PUBLIC_IP\`"
    MSG_BAL_LABEL="- Balances:"
    
    MESSAGE=$(printf "%s\n%s\n%s\n%s\n\n\`\`\`\n%s\n\`\`\`" \
        "$MSG_HEADER" "$MSG_CONV" "$MSG_IP" "$MSG_BAL_LABEL" "$FORMATTED_BAL")
    
    jq -n --arg content "$MESSAGE" '{content:$content}' | \
        curl -s -X POST -H "Content-Type: application/json" -d @- "$DISCORD_WEBHOOK_URL" >/dev/null
    
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
done

echo ""
echo "==== FINAL SUMMARY ===="
echo "📊 Total requests sent: $REQUESTS_SENT"
echo "✅ Successfully processed: $PROCESSED_COUNT"
echo "❌ Missing callbacks: $MISSING_COUNT"
echo "📁 Results saved to: results.csv"

if [[ $MISSING_COUNT -gt 0 ]]; then
    echo ""
    echo "⚠️  Warning: Some callbacks were not received. This may be due to:"
    echo "   - M-Pesa API delays (callbacks can take 30-60 seconds)"
    echo "   - Network issues"
    echo "   - Invalid credentials"
    echo ""
    echo "💡 Tip: Increase WAIT_SECONDS if callbacks are consistently missing"
fi
