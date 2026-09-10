#!/usr/bin/env bash
set -euo pipefail
umask 077

VERSION="1.1.1"

CURRENT_AUTH_FILE="${CURRENT_AUTH_FILE:-$HOME/.codex/auth.json}"

MODE="show"
AUTH_FILE="$HOME/.codex/auth-poll.json"

if [[ $# -ge 1 ]]; then
  case "$1" in
    version|--version|-v)
      printf "%s\n" "$VERSION"
      exit 0
      ;;
    help|--help|-h)
      printf 'Usage: %s [show|switch|--version] [auth-pool.json]\n' "${0##*/}"
      exit 0
      ;;
    switch)
      MODE="switch"
      shift
      ;;
    show)
      MODE="show"
      shift
      ;;
  esac
fi

if [[ $# -gt 1 || ( $# -eq 1 && "$1" == -* ) ]]; then
  echo "Error: invalid arguments; use --help." >&2
  exit 1
fi
if [[ $# -eq 1 ]]; then
  AUTH_FILE="$1"
fi
if [[ "$MODE" == "switch" && ( ! -t 0 || ! -t 1 ) ]]; then
  echo "Error: switch requires an interactive terminal." >&2
  exit 1
fi

POOL_FILE="$AUTH_FILE"
USAGE_URL="https://chatgpt.com/backend-api/wham/usage"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'
REVERSE=$'\033[7m'
if [[ ! -t 1 || -n "${NO_COLOR:-}" ]]; then
  RED='' GREEN='' YELLOW='' BOLD='' DIM='' RESET='' REVERSE=''
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required but not installed." >&2
  exit 1
fi

cleanup() {
  [[ -z "${TMP_UPSERT_FILE:-}" ]] || rm -f -- "$TMP_UPSERT_FILE"
  [[ -z "${TMP_SWITCH_FILE:-}" ]] || rm -f -- "$TMP_SWITCH_FILE"
  [[ -z "${WORK_DIR:-}" ]] || rm -rf -- "$WORK_DIR"
  [[ -z "${POOL_LOCK:-}" ]] || rmdir -- "$POOL_LOCK"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

WORK_DIR="$(mktemp -d)"

# Reject ambiguous file targets before reading or replacing credentials.
for auth_path in "$CURRENT_AUTH_FILE" "$POOL_FILE"; do
  if [[ -L "$auth_path" || ( -e "$auth_path" && ! -f "$auth_path" ) ]]; then
    echo "Error: auth paths must be regular files, not symlinks." >&2
    exit 1
  fi
done
if [[ "$CURRENT_AUTH_FILE" == "$POOL_FILE" || "$CURRENT_AUTH_FILE" -ef "$POOL_FILE" ]]; then
  echo "Error: current auth and pool must be different files." >&2
  exit 1
fi


get_auth_mode() {
  jq -r '.auth_mode // "apikey"' <<<"$1"
}

get_auth_identity() {
  local raw="$1"
  local mode
  mode="$(get_auth_mode "$raw")"

  case "$mode" in
    chatgpt)
      jq -r '.tokens.account_id // empty' <<<"$raw"
      ;;
    apikey)
      jq -r '.OPENAI_API_KEY // empty' <<<"$raw"
      ;;
    *)
      echo ""
      ;;
  esac
}

get_auth_label() {
  local raw="$1"
  local mode
  mode="$(get_auth_mode "$raw")"

  case "$mode" in
    chatgpt)
      jq -r '.tokens.account_id // "unknown-account"' <<<"$raw"
      ;;
    apikey)
      local key
      key="$(jq -r '.OPENAI_API_KEY // ""' <<<"$raw")"
      if [[ -z "$key" ]]; then
        echo "unknown-apikey"
      else
        if (( ${#key} > 8 )); then
          printf "apikey:...%s" "${key: -4}"
        else
          printf "apikey:[redacted]"
        fi
      fi
      ;;
    *)
      echo "unknown-auth"
      ;;
  esac
}

is_current_auth() {
  local raw="$1"
  local id
  id="$(get_auth_identity "$raw")"
  [[ -n "$id" && "$id" == "$CURRENT_AUTH_IDENTITY" ]]
}

# Validate the complete document before any persistent modification.
AUTH_SCHEMA='
  def safe_string: type == "string" and length > 0 and
    (test("[\u0000-\u001f\u007f]") | not);
  def valid_auth:
    type == "object" and (
      ((.auth_mode // "apikey") == "chatgpt" and
        (.tokens | type == "object") and
        (.tokens.account_id | safe_string) and
        (.tokens.access_token == null or
          (.tokens.access_token | safe_string))) or
      ((.auth_mode // "apikey") == "apikey" and
        (.OPENAI_API_KEY | safe_string))
    );
'
if [[ ! -f "$CURRENT_AUTH_FILE" ]]; then
  echo "Error: current auth file not found: $CURRENT_AUTH_FILE" >&2
  exit 1
fi
cp -- "$CURRENT_AUTH_FILE" "$WORK_DIR/current.json"
jq -e -s "$AUTH_SCHEMA length == 1 and (.[0] | valid_auth)" \
  "$WORK_DIR/current.json" >/dev/null || {
  echo "Error: invalid current auth document." >&2
  exit 1
}

if ! mkdir -- "${POOL_FILE}.lock" 2>/dev/null; then
  echo "Error: pool is locked or its directory is unavailable: ${POOL_FILE}.lock" >&2
  exit 1
fi
POOL_LOCK="${POOL_FILE}.lock"
if [[ -f "$POOL_FILE" ]]; then
  jq -e -s "$AUTH_SCHEMA length == 1 and (.[0] | type == \"array\" and all(.[]; valid_auth))" \
    "$POOL_FILE" >/dev/null || {
    echo "Error: invalid auth pool document." >&2
    exit 1
  }
  cp -- "$POOL_FILE" "$WORK_DIR/pool.json"
else
  printf '[]\n' > "$WORK_DIR/pool.json"
fi

TMP_UPSERT_FILE="$(mktemp "${POOL_FILE}.tmp.XXXXXX")"

jq --slurpfile new_auth "$WORK_DIR/current.json" '
  def auth_identity($a):
    if (($a.auth_mode // "apikey")) == "chatgpt" then
      ($a.tokens.account_id // "")
    elif (($a.auth_mode // "apikey")) == "apikey" then
      ($a.OPENAI_API_KEY // "")
    else
      ""
    end;

  . as $pool
  | $new_auth[0] as $new
  | auth_identity($new) as $new_id
  | if ($new_id | length) == 0 then
      .
    elif any($pool[]?; auth_identity(.) == $new_id) then
      map(
        if auth_identity(.) == $new_id
        then $new
        else .
        end
      )
    else
      . + [$new]
    end
' "$WORK_DIR/pool.json" > "$TMP_UPSERT_FILE"

cp -- "$TMP_UPSERT_FILE" "$WORK_DIR/pool.json"
mv -f -- "$TMP_UPSERT_FILE" "$POOL_FILE"
rmdir -- "$POOL_LOCK"
unset POOL_LOCK
unset TMP_UPSERT_FILE

CURRENT_AUTH_RAW="$(cat "$WORK_DIR/current.json")"
CURRENT_AUTH_IDENTITY="$(get_auth_identity "$CURRENT_AUTH_RAW")"

if [[ ! -f "$AUTH_FILE" ]]; then
  echo "Error: auth pool file not found: $AUTH_FILE" >&2
  exit 1
fi

is_number() {
  [[ "${1:-}" =~ ^(0|[1-9][0-9]{0,10})$ ]]
}

parse_to_epoch() {
  local value="${1:-}"

  [[ -z "$value" || "$value" == "null" ]] && return 1

  if is_number "$value"; then
    echo "$value"
    return 0
  fi

  if date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s >/dev/null 2>&1; then
    date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s
    return 0
  fi

  if date -u -d "$value" +%s >/dev/null 2>&1; then
    date -u -d "$value" +%s
    return 0
  fi

  return 1
}

format_abs_time() {
  local epoch="$1"

  if date -u -r "$epoch" "+%Y-%m-%d %H:%M UTC" >/dev/null 2>&1; then
    date -u -r "$epoch" "+%Y-%m-%d %H:%M UTC"
    return 0
  fi

  if date -u -d "@$epoch" "+%Y-%m-%d %H:%M UTC" >/dev/null 2>&1; then
    date -u -d "@$epoch" "+%Y-%m-%d %H:%M UTC"
    return 0
  fi

  echo "$epoch"
}

format_relative_time() {
  local epoch="$1"
  local now diff sign days hours mins

  now="$(date -u +%s)"
  diff=$(( epoch - now ))
  sign=""

  if (( diff < 0 )); then
    diff=$(( -diff ))
    sign="-"
  fi

  days=$(( diff / 86400 ))
  hours=$(( (diff % 86400) / 3600 ))
  mins=$(( (diff % 3600) / 60 ))

  if (( days > 0 )); then
    echo "${sign}${days}d ${hours}hr"
  elif (( hours > 0 )); then
    echo "${sign}${hours}hr ${mins}m"
  else
    echo "${sign}${mins}m"
  fi
}

format_reset_at() {
  local raw="${1:-}"
  local epoch abs rel

  if ! epoch="$(parse_to_epoch "$raw")"; then
    echo "-"
    return
  fi

  is_number "$epoch" || { echo "-"; return; }
  abs="$(format_abs_time "$epoch")"
  rel="$(format_relative_time "$epoch")"
  echo "${rel} (${abs})"
}

remaining_percent() {
  local used="${1:-}"

  if [[ -z "$used" || "$used" == "null" || "$used" == "-" ]]; then
    echo "-"
    return
  fi

  if ! [[ "$used" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "-"
    return
  fi

  awk -v u="$used" 'BEGIN {
    r = 100 - u
    if (r < 0) r = 0
    if (r == int(r)) printf "%d", r
    else printf "%.1f", r
  }'
}

colorize_remaining() {
  local val="${1:-}"

  if [[ -z "$val" || "$val" == "-" ]]; then
    printf "%s" "$val"
    return
  fi

  if ! [[ "$val" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf "%s" "$val"
    return
  fi

  awk -v v="$val" -v red="$RED" -v yellow="$YELLOW" -v green="$GREEN" -v reset="$RESET" '
    BEGIN {
      if (v <= 10)      printf "%s%s%%%s", red, v, reset;
      else if (v <= 25) printf "%s%s%%%s", yellow, v, reset;
      else              printf "%s%s%%%s", green, v, reset;
    }
  '
}

http_error_text() {
  local code="${1:-}"
  case "$code" in
    401) echo "HTTP 401 Unauthorized" ;;
    403) echo "HTTP 403 Forbidden" ;;
    404) echo "HTTP 404 Not Found" ;;
    429) echo "HTTP 429 Too Many Requests" ;;
    500) echo "HTTP 500 Internal Server Error" ;;
    502) echo "HTTP 502 Bad Gateway" ;;
    503) echo "HTTP 503 Service Unavailable" ;;
    000) echo "Network error or request timed out" ;;
    *) echo "HTTP $code" ;;
  esac
}

fetch_usage_for_account() {
  local raw_account="$1"
  local auth_mode display_name is_current
  local access_token account_id email plan_type limit_reached
  local primary_used primary_reset secondary_used secondary_reset
  local primary_remaining secondary_remaining
  local primary_reset_fmt secondary_reset_fmt
  local primary_remaining_num
  local response_body http_code tmp_body

  auth_mode="$(get_auth_mode "$raw_account")"
  display_name="$(get_auth_label "$raw_account")"
  is_current="false"
  is_current_auth "$raw_account" && is_current="true"

  if [[ "$auth_mode" == "apikey" ]]; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$display_name" \
      --arg is_current "$is_current" \
      --slurpfile raw_auth "$WORK_DIR/account.json" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "apikey",
        limit_reached: "n/a",
        primary_remaining_num: 9998,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: "usage check skipped for apikey auth",
        raw_auth: $raw_auth[0]
      }'
    return
  fi

  access_token="$(jq -r '.tokens.access_token // empty' <<<"$raw_account")"
  account_id="$(jq -r '.tokens.account_id // "unknown-account"' <<<"$raw_account")"

  if [[ -z "$access_token" ]]; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg is_current "$is_current" \
      --slurpfile raw_auth "$WORK_DIR/account.json" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "unknown",
        limit_reached: "error",
        primary_remaining_num: 9999,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: "missing access_token",
        raw_auth: $raw_auth[0]
      }'
    return
  fi

  tmp_body="$WORK_DIR/response.json"
  # Headers travel through stdin, never through the process argument list.
  # -q disables ~/.curlrc; do not follow redirects with credentials.
  if ! http_code="$(
    printf 'Authorization: Bearer %s\nChatGPT-Account-Id: %s\n' "$access_token" "$account_id" |
      curl -q -sS --proto '=https' --connect-timeout 10 --max-time 30 \
        --max-filesize 1048576 -o "$tmp_body" -w '%{http_code}' \
        -H @- -H 'accept: application/json' "$USAGE_URL"
  )"; then
    http_code="000"
  fi
  response_body="$(cat "$tmp_body" 2>/dev/null || true)"
  rm -f "$tmp_body"

  if [[ "$http_code" != "200" ]]; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg is_current "$is_current" \
      --arg query_error "$(http_error_text "$http_code")" \
      --slurpfile raw_auth "$WORK_DIR/account.json" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "unknown",
        limit_reached: "error",
        primary_remaining_num: 9999,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: $query_error,
        raw_auth: $raw_auth[0]
      }'
    return
  fi

  if [[ -z "$response_body" ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$response_body"; then
    jq -n \
      --arg auth_mode "$auth_mode" \
      --arg account_id "$account_id" \
      --arg is_current "$is_current" \
      --slurpfile raw_auth "$WORK_DIR/account.json" \
      '{
        auth_mode: $auth_mode,
        account_id: $account_id,
        is_current: ($is_current == "true"),
        email: $account_id,
        plan_type: "unknown",
        limit_reached: "error",
        primary_remaining_num: 9999,
        primary_remaining: "-",
        primary_reset_fmt: "-",
        secondary_remaining: "-",
        secondary_reset_fmt: "-",
        query_error: "invalid response body",
        raw_auth: $raw_auth[0]
      }'
    return
  fi

  email="$(jq -r '
    .email //
    .account.email //
    .user.email //
    .viewer.email //
    .account_email //
    "unknown"
  ' <<<"$response_body")"

  plan_type="$(jq -r '
    .plan_type //
    .account.plan_type //
    .subscription.plan_type //
    .plan.type //
    "unknown"
  ' <<<"$response_body")"

  limit_reached="$(jq -r '
    .rate_limit.limit_reached //
    .limit_reached //
    false
  ' <<<"$response_body")"

  primary_used="$(jq -r '
    .rate_limit.primary_window.used_percent //
    .primary_window.used_percent //
    "-"
  ' <<<"$response_body")"

  primary_reset="$(jq -r '
    .rate_limit.primary_window.reset_at //
    .primary_window.reset_at //
    empty
  ' <<<"$response_body")"

  secondary_used="$(jq -r '
    .rate_limit.secondary_window.used_percent //
    .secondary_window.used_percent //
    "-"
  ' <<<"$response_body")"

  secondary_reset="$(jq -r '
    .rate_limit.secondary_window.reset_at //
    .secondary_window.reset_at //
    empty
  ' <<<"$response_body")"

  primary_remaining="$(remaining_percent "$primary_used")"
  secondary_remaining="$(remaining_percent "$secondary_used")"
  primary_reset_fmt="$(format_reset_at "$primary_reset")"
  secondary_reset_fmt="$(format_reset_at "$secondary_reset")"

  primary_remaining_num="$primary_remaining"
  if [[ "$primary_remaining_num" == "-" || -z "$primary_remaining_num" ]]; then
    primary_remaining_num="9999"
  fi

  jq -n \
    --arg auth_mode "$auth_mode" \
    --arg account_id "$account_id" \
    --arg is_current "$is_current" \
    --arg email "$email" \
    --arg plan_type "$plan_type" \
    --arg limit_reached "$limit_reached" \
    --arg primary_remaining "$primary_remaining" \
    --arg primary_remaining_num "$primary_remaining_num" \
    --arg primary_reset_fmt "$primary_reset_fmt" \
    --arg secondary_remaining "$secondary_remaining" \
    --arg secondary_reset_fmt "$secondary_reset_fmt" \
    --slurpfile raw_auth "$WORK_DIR/account.json" \
    '{
      auth_mode: $auth_mode,
      account_id: $account_id,
      is_current: ($is_current == "true"),
      email: $email,
      plan_type: $plan_type,
      limit_reached: $limit_reached,
      primary_remaining_num: ($primary_remaining_num | tonumber),
      primary_remaining: $primary_remaining,
      primary_reset_fmt: $primary_reset_fmt,
      secondary_remaining: $secondary_remaining,
      secondary_reset_fmt: $secondary_reset_fmt,
      raw_auth: $raw_auth[0]
    }'
}

build_results() {
  RESULTS_FILE="$WORK_DIR/results.jsonl"
  : > "$RESULTS_FILE"
  jq -c '.[]' "$WORK_DIR/pool.json" | while IFS= read -r account; do
    printf '%s\n' "$account" > "$WORK_DIR/account.json"
    fetch_usage_for_account "$account" >> "$RESULTS_FILE"
    echo >> "$RESULTS_FILE"
  done
}

sort_results_to_json() {
  jq -s '
    map(with_entries(
      if .key != "raw_auth" and (.value | type) == "string" then
        .value |= gsub("[\u0000-\u001f\u007f-\u009f]"; "?")
      else . end
    ))
    | sort_by((if .is_current then 0 else 1 end), .primary_remaining_num, .email)
  ' "$RESULTS_FILE"
}

render_show_mode() {
  printf "${DIM}Codex usage from: %s${RESET}\n" "$AUTH_FILE"
  printf "${DIM}Current auth: %s${RESET}\n\n" "$CURRENT_AUTH_FILE"

  sort_results_to_json | jq -c '.[]' | while IFS= read -r item; do
    local email plan_type limit_reached primary_remaining primary_reset_fmt
    local secondary_remaining secondary_reset_fmt is_current query_error
    local primary_remaining_colored secondary_remaining_colored auth_mode

    email="$(jq -r '.email' <<<"$item")"
    plan_type="$(jq -r '.plan_type' <<<"$item")"
    limit_reached="$(jq -r '.limit_reached' <<<"$item")"
    primary_remaining="$(jq -r '.primary_remaining' <<<"$item")"
    primary_reset_fmt="$(jq -r '.primary_reset_fmt' <<<"$item")"
    secondary_remaining="$(jq -r '.secondary_remaining' <<<"$item")"
    secondary_reset_fmt="$(jq -r '.secondary_reset_fmt' <<<"$item")"
    is_current="$(jq -r '.is_current' <<<"$item")"
    query_error="$(jq -r '.query_error // empty' <<<"$item")"
    auth_mode="$(jq -r '.auth_mode // "apikey"' <<<"$item")"

    primary_remaining_colored="$(colorize_remaining "$primary_remaining")"
    secondary_remaining_colored="$(colorize_remaining "$secondary_remaining")"

    if [[ "$is_current" == "true" ]]; then
      printf "Account: %s [%s] (%s) ${BOLD}${GREEN}[Current Using]${RESET}" "$email" "$plan_type" "$auth_mode"
    else
      printf "Account: %s [%s] (%s)" "$email" "$plan_type" "$auth_mode"
    fi

    if [[ -n "$query_error" ]]; then
      printf "  ${RED}%s${RESET}\n" "$query_error"
      printf "\n"
      continue
    else
      printf "\n"
    fi

    if [[ "$limit_reached" == "true" ]]; then
      printf "Rate Limit: ${RED}%s${RESET}\n" "$limit_reached"
    else
      printf "Rate Limit: ${GREEN}%s${RESET}\n" "$limit_reached"
    fi

    printf "  5h remaining: %s  reset at: %s\n" "$primary_remaining_colored" "$primary_reset_fmt"
    printf "  1w remaining: %s  reset at: %s\n" "$secondary_remaining_colored" "$secondary_reset_fmt"
    printf "\n"
  done
}

draw_switch_ui() {
  local selected="$1"
  local json="$2"
  local count idx

  count="$(jq 'length' <<<"$json")"

  printf "\033[H\033[J"
  printf "${BOLD}Select account to switch${RESET}  ${DIM}(↑/↓ move, Enter confirm, q quit)${RESET}\n\n"

  for (( idx=0; idx<count; idx++ )); do
    local item email plan_type is_current limit_reached auth_mode
    local p5 p1w qerr line prefix

    item="$(jq -c ".[$idx]" <<<"$json")"
    email="$(jq -r '.email' <<<"$item")"
    plan_type="$(jq -r '.plan_type' <<<"$item")"
    is_current="$(jq -r '.is_current' <<<"$item")"
    limit_reached="$(jq -r '.limit_reached' <<<"$item")"
    p5="$(jq -r '.primary_remaining' <<<"$item")"
    p1w="$(jq -r '.secondary_remaining' <<<"$item")"
    qerr="$(jq -r '.query_error // empty' <<<"$item")"
    auth_mode="$(jq -r '.auth_mode // "apikey"' <<<"$item")"

    prefix="  "
    [[ "$idx" -eq "$selected" ]] && prefix="> "

    line="${prefix}${email} [${plan_type}] (${auth_mode})"

    if [[ -n "$qerr" ]]; then
      line="${line}  ${RED}${qerr}${RESET}"
    else
      local p5c p1wc
      p5c="$(colorize_remaining "$p5")"
      p1wc="$(colorize_remaining "$p1w")"

      if [[ "$limit_reached" == "true" ]]; then
        line="${line}  RL:${RED}true${RESET}  5h:${p5c}  1w:${p1wc}"
      else
        line="${line}  RL:${GREEN}false${RESET}  5h:${p5c}  1w:${p1wc}"
      fi
    fi

    if [[ "$is_current" == "true" ]]; then
      line="${line} ${BOLD}${GREEN}[Current Using]${RESET}"
    fi

    if [[ "$idx" -eq "$selected" ]]; then
      printf "${REVERSE}%s${RESET}\n" "$line"
    else
      printf "%s\n" "$line"
    fi
  done

  printf "\n${DIM}Current auth file: %s${RESET}\n" "$CURRENT_AUTH_FILE"
  printf "${DIM}Auth pool file: %s${RESET}\n" "$AUTH_FILE"
}

switch_mode() {
  local sorted_json selected count key item target_label
  sorted_json="$(sort_results_to_json)"
  count="$(jq 'length' <<<"$sorted_json")"

  if [[ "$count" -eq 0 ]]; then
    echo "No accounts found in $AUTH_FILE" >&2
    exit 1
  fi

  selected=0

  while true; do
    draw_switch_ui "$selected" "$sorted_json"

    if ! IFS= read -rsn1 key; then
      printf "\nCancelled (input closed).\n"
      break
    fi

    if [[ "$key" == "q" || "$key" == "Q" ]]; then
      printf "\nCancelled.\n"
      break
    fi

    if [[ "$key" == "" ]]; then
      item="$(jq -c ".[$selected]" <<<"$sorted_json")"
      printf "\033[H\033[J"
      printf "Switching current account...\n"

      if [[ -L "$CURRENT_AUTH_FILE" ]] || ! cmp -s -- "$CURRENT_AUTH_FILE" "$WORK_DIR/current.json"; then
        echo "Error: current auth changed while selecting; retry." >&2
        exit 1
      fi
      TMP_SWITCH_FILE="$(mktemp "${CURRENT_AUTH_FILE}.tmp.XXXXXX")"
      jq '.raw_auth' <<<"$item" > "$TMP_SWITCH_FILE"
      mv -f -- "$TMP_SWITCH_FILE" "$CURRENT_AUTH_FILE"
      unset TMP_SWITCH_FILE

      target_label="$(jq -r '.email' <<<"$item")"

      printf "${GREEN}${BOLD}Switched.${RESET}\n"
      printf "Current account: %s\n" "$target_label"
      printf "Updated auth file: %s\n" "$CURRENT_AUTH_FILE"
      break
    fi

    if [[ "$key" == $'\x1b' ]]; then
      IFS= read -rsn2 -t 1 key || true
      case "$key" in
        "[A")
          if (( selected > 0 )); then selected=$((selected - 1)); fi
          ;;
        "[B")
          if (( selected < count - 1 )); then selected=$((selected + 1)); fi
          ;;
      esac
    fi
  done
}

build_results

if [[ "$MODE" == "switch" ]]; then
  switch_mode
else
  render_show_mode
fi