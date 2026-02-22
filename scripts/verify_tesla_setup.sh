#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="${1:-$HOME/Library/Application Support/TeslaNotifier/config.json}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-15}"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "PASS: $*"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  echo "WARN: $*"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "FAIL: $*"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

echo "Tesla Notifier setup verification"
echo "Config: $CONFIG_PATH"
echo

if [[ ! -f "$CONFIG_PATH" ]]; then
  fail "Config file not found."
  echo
  echo "Summary: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"
  exit 1
fi

if ! have_cmd python3; then
  fail "python3 is required."
  echo
  echo "Summary: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"
  exit 1
fi

CFG_JSON="$(python3 - <<'PY' "$CONFIG_PATH"
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
print(json.dumps(cfg))
PY
)" || {
  fail "Config is not valid JSON."
  echo
  echo "Summary: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"
  exit 1
}

cfg_get() {
  python3 - <<'PY' "$CFG_JSON" "$1"
import json, sys
cfg = json.loads(sys.argv[1])
key = sys.argv[2]
value = cfg.get(key, "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

TARGET_RECIPIENT="$(cfg_get targetRecipient)"
WHATSAPP_DB_PATH="$(cfg_get whatsappDBPath)"
GATE_MODE="$(cfg_get forwardingGateMode)"
FAIL_OPEN="$(cfg_get forwardingGateFailOpen)"
FLEET_URL="$(cfg_get teslaFleetVehicleDataURL)"
FLEET_TOKEN="$(cfg_get teslaFleetBearerToken)"
FLEET_REFRESH_TOKEN="$(cfg_get teslaFleetRefreshToken)"
TESLA_CLIENT_ID="$(cfg_get teslaOAuthClientID)"
TESLA_CLIENT_SECRET="$(cfg_get teslaOAuthClientSecret)"

if [[ -n "$TARGET_RECIPIENT" && "$TARGET_RECIPIENT" != "+15555555555" && "$TARGET_RECIPIENT" != "+1YOUR_NUMBER" ]]; then
  pass "targetRecipient configured: $TARGET_RECIPIENT"
else
  fail "targetRecipient is missing or placeholder."
fi

if [[ -f "$WHATSAPP_DB_PATH" ]]; then
  if /usr/bin/sqlite3 -readonly "$WHATSAPP_DB_PATH" 'select 1;' >/dev/null 2>&1; then
    pass "WhatsApp DB is readable."
  else
    fail "WhatsApp DB exists but is not readable (likely Full Disk Access issue)."
  fi
else
  fail "WhatsApp DB not found at configured path."
fi

if /usr/bin/osascript -e 'tell application "Messages" to get id of first service whose enabled is true' >/dev/null 2>&1; then
  pass "Messages automation access appears available."
else
  fail "Messages automation access failed (grant Automation permission)."
fi

GATE_MODE_LOWER="$(echo "$GATE_MODE" | tr '[:upper:]' '[:lower:]' | xargs)"
if [[ "$GATE_MODE_LOWER" == "tesla_fleet" ]]; then
  pass "forwardingGateMode=tesla_fleet"

  if [[ -z "$FLEET_URL" ]]; then
    fail "teslaFleetVehicleDataURL is empty."
  else
    pass "teslaFleetVehicleDataURL is set."
  fi

  TOKEN_PARTS="$(echo "$FLEET_TOKEN" | awk -F. '{print NF}')"
  if [[ "$TOKEN_PARTS" == "3" ]]; then
    pass "teslaFleetBearerToken format looks valid (JWT with 3 parts)."
  else
    fail "teslaFleetBearerToken format is invalid."
  fi

  if [[ -n "$FLEET_REFRESH_TOKEN" && -n "$TESLA_CLIENT_ID" && -n "$TESLA_CLIENT_SECRET" ]]; then
    pass "auto-refresh credentials are configured."
  else
    warn "auto-refresh credentials missing; token expiry will require manual update."
  fi

  if [[ -n "$FLEET_URL" && "$TOKEN_PARTS" == "3" ]] && have_cmd curl; then
    RESP_FILE="$(mktemp)"
    HTTP_CODE="$(curl -sS -m "$TIMEOUT_SECONDS" -o "$RESP_FILE" -w '%{http_code}' \
      -H "Authorization: Bearer $FLEET_TOKEN" \
      -H "Accept: application/json" \
      "$FLEET_URL" || true)"
    BODY="$(cat "$RESP_FILE" 2>/dev/null || true)"
    rm -f "$RESP_FILE"

    if [[ "$HTTP_CODE" == "200" ]]; then
      USER_PRESENT="$(python3 - <<'PY' "$BODY"
import json, sys
try:
    body = json.loads(sys.argv[1] or "{}")
except Exception:
    body = {}
resp = body.get("response", {})
vs = resp.get("vehicle_state", {}) if isinstance(resp, dict) else {}
v = vs.get("is_user_present", None)
if v is True:
    print("true")
elif v is False:
    print("false")
else:
    print("null")
PY
)"
      pass "Fleet API reachable (HTTP 200), is_user_present=$USER_PRESENT"
    elif [[ "$HTTP_CODE" == "408" ]]; then
      warn "Fleet API HTTP 408 (vehicle offline/asleep). With forwardingGateFailOpen=$FAIL_OPEN this may block forwarding."
    elif [[ "$HTTP_CODE" == "401" ]]; then
      fail "Fleet API HTTP 401 (token invalid/expired)."
    elif [[ -z "$HTTP_CODE" || "$HTTP_CODE" == "000" ]]; then
      fail "Fleet API request failed (network/timeout)."
    else
      ERR_MSG="$(python3 - <<'PY' "$BODY"
import json, sys
try:
    body = json.loads(sys.argv[1] or "{}")
except Exception:
    body = {}
print(body.get("error",""))
PY
)"
      warn "Fleet API HTTP $HTTP_CODE ${ERR_MSG:+error=$ERR_MSG}"
    fi
  fi
else
  warn "forwardingGateMode is '$GATE_MODE' (not tesla_fleet); Fleet checks skipped."
fi

echo
echo "Summary: PASS=$PASS_COUNT WARN=$WARN_COUNT FAIL=$FAIL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
