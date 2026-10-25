#!/usr/bin/env bash
#
# update_channel_one.sh - point a Dispatcharr channel at a newly added stream.
#
# Three ways to use it:
#
#   1. Interactive picker (SSH / terminal):
#        DISPATCHARR_URL=http://192.168.2.10:9191 \
#        DISPATCHARR_API_TOKEN=... \
#        ./update_channel_one.sh
#
#   2. List the newest streams:
#        ./update_channel_one.sh --list
#        ./update_channel_one.sh --list --format json
#
#      Add --refresh to pull the M3U playlists from the providers first, so a
#      channel the provider just added shows up in the list:
#        ./update_channel_one.sh --refresh --list
#
#   3. Non-interactive assign (what OliveTin calls):
#        ./update_channel_one.sh --assign 12345 --yes
#
# OliveTin cannot show a TTY dialog from its web UI, so the integration uses
# OliveTin's own entity-backed dropdown instead:
#
#        ./update_channel_one.sh --list --format entities \
#          --output /tmp/olivetin-entities/dispatcharr-streams.json
#
# OliveTin wiring (kubernetes/apps/default/olivetin/app):
#   - config.yaml:
#       "Seed Dispatcharr Stream Picker" is hidden and runs on startup; it
#       only writes a placeholder entity if the file is missing, so the
#       picker has valid data after a pod restart without reading Dispatcharr;
#       "Refresh M3U & Stream List" pulls the providers, waits, and rewrites
#       the entity file; nothing reads Dispatcharr on a schedule or on startup,
#       so Dispatcharr is only read when you tap an action;
#       "Assign Stream to Channel 1" renders the entity as a dropdown and
#       calls this script with --assign <id> --yes. Channel 1 is a temporary
#       hold channel, so the action always replaces its stream list.
#   - helmrelease.yaml: mounts this script and sets DISPATCHARR_URL,
#     DISPATCHARR_CHANNEL_NUMBER and DISPATCHARR_API_TOKEN.
#   - externalsecret.yaml: 'olivetin-dispatcharr' reads DISPATCHARR_API_TOKEN
#     from the GitLab 'dispatcharr' secret (same JSON as the Postgres creds).
#
# Dispatcharr API notes:
#   - Two route layouts exist: newer builds serve /api/streams/ and
#     /api/channels/, while 0.32.x serves /api/channels/streams/ and
#     /api/channels/channels/. Each run probes both and uses whichever
#     returns a DRF list, so a Dispatcharr upgrade cannot silently break it.
#   - The streams list is paginated (page_size max 10000) and its ordering
#     filter does not expose id/updated_at. Streams are therefore sorted by
#     id client-side; ids auto-increment and re-seen streams keep their row,
#     so the highest id is the most recently added stream.
#   - The channel list has no channel_number filter, so the target is found
#     client-side by effective_channel_number (falling back to
#     channel_number). If the number is duplicated, set
#     DISPATCHARR_CHANNEL_ID instead.
#   - PATCH <channel detail> {"streams": [<stream_id>]} replaces the
#     channel's stream list (order 0). --keep-existing prepends the new
#     stream and keeps the old ones as backups.
#   - --refresh POSTs /api/m3u/refresh/ (or /api/m3u/refresh/<account_id>/)
#     and polls /api/m3u/accounts/ until every active account leaves the
#     fetching/parsing states, so the list is rebuilt from fresh provider
#     data. This is a Celery task; a busy worker can delay the start.
#   - API-key auth (X-API-Key) requires Dispatcharr 0.20 or newer.
#
# Environment:
#   DISPATCHARR_URL             required  e.g. http://dispatcharr.media.svc.cluster.local:9191
#   DISPATCHARR_API_TOKEN       required  Dispatcharr profile -> API key
#   DISPATCHARR_CHANNEL_NUMBER  optional  target channel number (default: 1)
#   DISPATCHARR_CHANNEL_ID      optional  target channel database id (overrides number)
#   DISPATCHARR_STREAM_LIMIT    optional  how many newest streams to show (default: 10)
#   DISPATCHARR_AUTH_SCHEME     optional  apikey (default) or bearer (JWT)
#   DISPATCHARR_VERIFY_TLS      optional  true (default) or false
#   DISPATCHARR_TIMEOUT         optional  curl timeout in seconds (default: 30)
#   DISPATCHARR_ENTITY_FILE     optional  default entity output path
#   DISPATCHARR_PICKER          optional  auto (default), whiptail, dialog or text
#   DISPATCHARR_M3U_REFRESH     optional  same as --refresh (default false)
#   DISPATCHARR_M3U_ACCOUNT_ID  optional  refresh only this M3U account
#   DISPATCHARR_M3U_REFRESH_TIMEOUT  optional  seconds to wait for the refresh (default 180)
#   DISPATCHARR_LOG_LEVEL       optional  DEBUG, INFO (default), WARN, ERROR
#
# Exit codes: 0 success/cancel, 1 error (config, API or runtime), 130 interrupted.

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_LEVEL="${DISPATCHARR_LOG_LEVEL:-INFO}"

level_number() {
  case "${1^^}" in
    DEBUG) printf '10' ;;
    INFO) printf '20' ;;
    WARN | WARNING) printf '30' ;;
    ERROR) printf '40' ;;
    *) printf '20' ;;
  esac
}

log() {
  local level="${1^^}"
  shift
  if (( $(level_number "${level}") >= $(level_number "${LOG_LEVEL}") )); then
    printf '%s %-5s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${level}" "$*" >&2
  fi
}

die() {
  log ERROR "$*"
  exit 1
}

placeholder_entity_json() {
  cat <<'JSON'
{"name":"No streams found","id":"","stream_name":"","label":"No streams found - run Refresh M3U & Stream List first","updated":"","stale":""}
JSON
}

usage() {
  cat <<EOF
${SCRIPT_NAME} ${VERSION} - assign a Dispatcharr stream to a channel.

Usage:
  ${SCRIPT_NAME} [options]

Modes:
  (default)                 Interactively pick one of the newest streams.
  --list                    List the newest streams and exit.
  --assign STREAM_ID        Assign STREAM_ID without a picker.
  --placeholder             Write a "no streams" entity placeholder and exit.
                            Does not contact Dispatcharr.

Options:
  --format table|json|entities
                            Output format for --list (default: table).
  --output PATH             Write --list/--placeholder output to PATH.
  --channel-number NUMBER   Target channel number (default: ${CHANNEL_NUMBER:-1}).
  --channel-id ID           Target channel database id (overrides number).
  --limit N                 Number of newest streams to show (default: 10).
  --refresh                 Pull the M3U playlists before listing streams.
  --keep-existing           Prepend the new stream, keep existing streams as backups.
  --yes, -y                 Skip the confirmation prompt (required when non-interactive).
  --dry-run                 Show the PATCH payload without changing anything.
  --verbose, -v             Enable DEBUG logging.
  --version                 Print the version.
  --help, -h                Show this help.

Environment:
  DISPATCHARR_URL           required, e.g. http://dispatcharr.media.svc.cluster.local:9191
  DISPATCHARR_API_TOKEN     required, Dispatcharr profile -> API key
  DISPATCHARR_CHANNEL_NUMBER  target channel number (default: 1)
  DISPATCHARR_CHANNEL_ID      target channel id (overrides number)
  DISPATCHARR_STREAM_LIMIT    newest streams to show (default: 10)
  DISPATCHARR_AUTH_SCHEME     apikey (default) or bearer
  DISPATCHARR_VERIFY_TLS      true (default) or false
  DISPATCHARR_TIMEOUT         curl timeout seconds (default: 30)
  DISPATCHARR_ENTITY_FILE     default entity output path
  DISPATCHARR_PICKER          auto (default), whiptail, dialog or text
  DISPATCHARR_M3U_REFRESH     same as --refresh (default false)
  DISPATCHARR_M3U_ACCOUNT_ID  refresh only this M3U account
  DISPATCHARR_M3U_REFRESH_TIMEOUT  seconds to wait for the refresh (default 180)
  DISPATCHARR_LOG_LEVEL       DEBUG, INFO (default), WARN, ERROR

Examples:
  ${SCRIPT_NAME} --list
  ${SCRIPT_NAME} --list --format entities --output /tmp/streams.json
  ${SCRIPT_NAME} --placeholder --output /tmp/streams.json
  ${SCRIPT_NAME} --assign 12345 --yes
  ${SCRIPT_NAME} --assign 12345 --keep-existing --yes
  ${SCRIPT_NAME} --dry-run --assign 12345 --yes
EOF
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DISPATCHARR_URL="${DISPATCHARR_URL:-}"
DISPATCHARR_API_TOKEN="${DISPATCHARR_API_TOKEN:-}"
CHANNEL_NUMBER="${DISPATCHARR_CHANNEL_NUMBER:-1}"
CHANNEL_ID="${DISPATCHARR_CHANNEL_ID:-}"
STREAM_LIMIT="${DISPATCHARR_STREAM_LIMIT:-10}"
AUTH_SCHEME="${DISPATCHARR_AUTH_SCHEME:-apikey}"
VERIFY_TLS="${DISPATCHARR_VERIFY_TLS:-true}"
TIMEOUT="${DISPATCHARR_TIMEOUT:-30}"
ENTITY_FILE="${DISPATCHARR_ENTITY_FILE:-/tmp/olivetin-entities/dispatcharr-streams.json}"
PICKER="${DISPATCHARR_PICKER:-auto}"
REFRESH_M3U="${DISPATCHARR_M3U_REFRESH:-false}"
M3U_ACCOUNT_ID="${DISPATCHARR_M3U_ACCOUNT_ID:-}"
M3U_REFRESH_TIMEOUT="${DISPATCHARR_M3U_REFRESH_TIMEOUT:-180}"

MODE="interactive"
FORMAT="table"
OUTPUT=""
STREAM_ID=""
ASSUME_YES="false"
DRY_RUN="false"
KEEP_EXISTING="false"

while (($#)); do
  case "$1" in
    --list)
      MODE="list"
      shift
      ;;
    --assign)
      (($# >= 2)) || die "--assign requires a stream id."
      STREAM_ID="$2"
      MODE="assign"
      shift 2
      ;;
    --assign=*)
      STREAM_ID="${1#*=}"
      MODE="assign"
      shift
      ;;
    --placeholder)
      MODE="placeholder"
      shift
      ;;
    --format)
      (($# >= 2)) || die "--format requires table, json or entities."
      FORMAT="$2"
      shift 2
      ;;
    --format=*)
      FORMAT="${1#*=}"
      shift
      ;;
    --output)
      (($# >= 2)) || die "--output requires a path."
      OUTPUT="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT="${1#*=}"
      shift
      ;;
    --channel-number)
      (($# >= 2)) || die "--channel-number requires a value."
      CHANNEL_NUMBER="$2"
      shift 2
      ;;
    --channel-id)
      (($# >= 2)) || die "--channel-id requires a value."
      CHANNEL_ID="$2"
      shift 2
      ;;
    --limit)
      (($# >= 2)) || die "--limit requires a value."
      STREAM_LIMIT="$2"
      shift 2
      ;;
    --refresh)
      REFRESH_M3U="true"
      shift
      ;;
    --keep-existing)
      KEEP_EXISTING="true"
      shift
      ;;
    --yes | -y)
      ASSUME_YES="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --verbose | -v)
      LOG_LEVEL="DEBUG"
      shift
      ;;
    --version)
      printf '%s %s\n' "${SCRIPT_NAME}" "${VERSION}"
      exit 0
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (try --help)"
      ;;
  esac
done

# Placeholder mode never talks to Dispatcharr, so it runs before the API
# validation below. OliveTin calls this on startup to keep the entity file
# valid after the emptyDir is recreated.
if [[ "${MODE}" == "placeholder" ]]; then
  placeholder_file="${OUTPUT:-${ENTITY_FILE}}"
  mkdir -p "$(dirname "${placeholder_file}")"

  if [[ -s "${placeholder_file}" ]]; then
    log INFO "Entity file ${placeholder_file} already exists; leaving it untouched."
  else
    placeholder_entity_json >"${placeholder_file}"
    log INFO "Wrote placeholder entity to ${placeholder_file}."
  fi

  exit 0
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
[[ -n "${DISPATCHARR_URL}" ]] ||
  die "DISPATCHARR_URL is not set (e.g. http://dispatcharr.media.svc.cluster.local:9191)."
[[ -n "${DISPATCHARR_API_TOKEN}" ]] ||
  die "DISPATCHARR_API_TOKEN is not set (create one in Dispatcharr: profile -> API key)."

[[ "${STREAM_LIMIT}" =~ ^[0-9]+$ ]] || die "DISPATCHARR_STREAM_LIMIT must be a positive integer."
((STREAM_LIMIT > 0)) || die "DISPATCHARR_STREAM_LIMIT must be greater than zero."

[[ "${CHANNEL_NUMBER}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  die "DISPATCHARR_CHANNEL_NUMBER must be a number (e.g. 1 or 1.5)."

# Normalize leading zeros so "01" is valid JSON for jq ("00.5" -> "0.5").
CHANNEL_NUMBER="$(printf '%s' "${CHANNEL_NUMBER}" | awk '{
  sub(/^0+/, "")
  if ($0 == "" || $0 ~ /^\./) $0 = "0" $0
  print
}')"

if [[ -n "${CHANNEL_ID}" ]]; then
  [[ "${CHANNEL_ID}" =~ ^[0-9]+$ ]] || die "DISPATCHARR_CHANNEL_ID must be a numeric channel id."
fi

case "${AUTH_SCHEME}" in
  apikey | bearer) ;;
  *) die "DISPATCHARR_AUTH_SCHEME must be 'apikey' or 'bearer'." ;;
esac

case "${VERIFY_TLS}" in
  true | false) ;;
  *) die "DISPATCHARR_VERIFY_TLS must be 'true' or 'false'." ;;
esac

[[ "${TIMEOUT}" =~ ^[0-9]+$ ]] || die "DISPATCHARR_TIMEOUT must be an integer number of seconds."

case "${FORMAT}" in
  table | json | entities) ;;
  *) die "--format must be table, json or entities." ;;
esac

case "${PICKER}" in
  auto | whiptail | dialog | text) ;;
  *) die "DISPATCHARR_PICKER must be auto, whiptail, dialog or text." ;;
esac

case "${REFRESH_M3U}" in
  true | false) ;;
  *) die "DISPATCHARR_M3U_REFRESH must be 'true' or 'false'." ;;
esac

if [[ -n "${M3U_ACCOUNT_ID}" ]]; then
  [[ "${M3U_ACCOUNT_ID}" =~ ^[0-9]+$ ]] || die "DISPATCHARR_M3U_ACCOUNT_ID must be a numeric account id."
fi

[[ "${M3U_REFRESH_TIMEOUT}" =~ ^[0-9]+$ ]] || die "DISPATCHARR_M3U_REFRESH_TIMEOUT must be an integer number of seconds."
((M3U_REFRESH_TIMEOUT > 0)) || die "DISPATCHARR_M3U_REFRESH_TIMEOUT must be greater than zero."

for tool in curl jq; do
  command -v "${tool}" >/dev/null 2>&1 || die "Required tool not found: ${tool}"
done

# Accept either http://host:9191 or http://host:9191/api as the base URL.
DISPATCHARR_URL="${DISPATCHARR_URL%/}"
[[ "${DISPATCHARR_URL}" == */api ]] && DISPATCHARR_URL="${DISPATCHARR_URL%/api}"

if [[ "${VERIFY_TLS}" == "false" ]]; then
  log WARN "TLS certificate verification is disabled (DISPATCHARR_VERIFY_TLS=false)."
fi

TMP_DIR="$(mktemp -d)" || die "Could not create a temporary directory."
trap 'rm -rf "${TMP_DIR}"' EXIT
trap 'log WARN "Interrupted."; exit 130' INT TERM

HTTP_STATUS=""
HTTP_BODY=""
SELECTED_STREAM=""
STREAMS_PATH=""
CHANNELS_PATH=""

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
api_error_message() {
  local message
  message="$(jq -r '
    if type == "object" then
      (.detail // .error // .message // tostring)
    else
      tostring
    end
  ' <<<"${HTTP_BODY}" 2>/dev/null || true)"
  [[ -n "${message}" && "${message}" != "null" ]] || message="${HTTP_BODY:-<empty response>}"
  printf '%s' "${message:0:500}"
}

# Raw request: sets HTTP_STATUS/HTTP_BODY, no error handling. Used by api()
# and by the route probes, which need to tolerate unexpected responses.
curl_api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local url="${DISPATCHARR_URL}${path}"
  local -a args=(
    --silent
    --show-error
    --connect-timeout 5
    --max-time "${TIMEOUT}"
    --retry 2
    --retry-delay 1
    --retry-connrefused
    --request "${method}"
    --header "Accept: application/json"
    --header "Content-Type: application/json"
    --output "${TMP_DIR}/response.json"
    --write-out '%{http_code}'
  )

  [[ "${VERIFY_TLS}" == "false" ]] && args+=(--insecure)

  # Keep the token out of the process list: curl reads the header from a
  # mode-600 file instead of the command line.
  local auth_header_file="${TMP_DIR}/auth.header"
  if [[ "${AUTH_SCHEME}" == "bearer" ]]; then
    printf 'Authorization: Bearer %s\n' "${DISPATCHARR_API_TOKEN}" >"${auth_header_file}"
  else
    printf 'X-API-Key: %s\n' "${DISPATCHARR_API_TOKEN}" >"${auth_header_file}"
  fi
  chmod 600 "${auth_header_file}"
  args+=(--header "@${auth_header_file}")

  [[ -n "${payload}" ]] && args+=(--data "${payload}")

  log DEBUG "${method} ${url}"

  local curl_rc=0
  HTTP_STATUS="$(curl "${args[@]}" "${url}")" || curl_rc=$?
  if ((curl_rc != 0)); then
    HTTP_BODY=""
    return "${curl_rc}"
  fi

  HTTP_BODY="$(cat "${TMP_DIR}/response.json" 2>/dev/null || true)"
  return 0
}

api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local curl_rc=0
  curl_api "${method}" "${path}" "${payload}" || curl_rc=$?
  if ((curl_rc != 0)); then
    die "Could not reach Dispatcharr at ${DISPATCHARR_URL} (curl exit ${curl_rc})."
  fi

  case "${HTTP_STATUS}" in
    2??)
      return 0
      ;;
    401)
      die "Dispatcharr rejected the API token (HTTP 401). Check DISPATCHARR_API_TOKEN; API keys require Dispatcharr 0.20 or newer."
      ;;
    403)
      die "Dispatcharr denied the request (HTTP 403). The API key's user must be an administrator to modify channels."
      ;;
    404)
      die "Dispatcharr returned HTTP 404 for ${path}. Check DISPATCHARR_URL, the channel id and the stream id."
      ;;
    *)
      die "Dispatcharr returned HTTP ${HTTP_STATUS} for ${path}: $(api_error_message)"
      ;;
  esac
}

# Fetch a paginated endpoint into an NDJSON file. Handles both a plain JSON
# array (pagination disabled) and DRF's {count,next,previous,results} shape.
fetch_paginated() {
  local path="$1"
  local output="$2"
  local page=1
  local page_size=10000

  : >"${output}"

  while :; do
    api GET "${path}?page=${page}&page_size=${page_size}"

    local shape
    shape="$(jq -r 'type' <<<"${HTTP_BODY}" 2>/dev/null)" ||
      die "Dispatcharr returned invalid JSON for ${path}."

    case "${shape}" in
      array)
        jq -c '.[]' <<<"${HTTP_BODY}" >>"${output}"
        break
        ;;
      object)
        jq -c '.results[]?' <<<"${HTTP_BODY}" >>"${output}"
        [[ -n "$(jq -r '.next // empty' <<<"${HTTP_BODY}")" ]] || break
        page=$((page + 1))
        ;;
      *)
        die "Unexpected JSON from ${path}: expected an array or a paginated object."
        ;;
    esac

    if ((page > 1000)); then
      die "Pagination for ${path} exceeded 1000 pages; aborting."
    fi
  done
}

# ---------------------------------------------------------------------------
# Route discovery
#
# Dispatcharr 0.32.x serves /api/channels/streams/ + /api/channels/channels/;
# newer builds serve /api/streams/ + /api/channels/. Probe once per run and
# remember which layout this instance uses.
# ---------------------------------------------------------------------------
is_drf_list() {
  jq -e '
    type == "array"
    or (type == "object" and ((.results? | type) == "array"))
  ' <<<"$1" >/dev/null 2>&1
}

probe_candidate() {
  local candidate="$1"

  curl_api GET "${candidate}?page=1&page_size=1" || return 1

  case "${HTTP_STATUS}" in
    401)
      die "Dispatcharr rejected the API token (HTTP 401). Check DISPATCHARR_API_TOKEN; API keys require Dispatcharr 0.20 or newer."
      ;;
    403)
      die "Dispatcharr denied the request (HTTP 403). The API key's user must be an administrator to modify channels."
      ;;
  esac

  [[ "${HTTP_STATUS}" == 2?? ]] && is_drf_list "${HTTP_BODY}"
}

ensure_streams_path() {
  if [[ -n "${STREAMS_PATH}" ]]; then
    return 0
  fi

  local candidate
  for candidate in "/api/streams/" "/api/channels/streams/"; do
    if probe_candidate "${candidate}"; then
      STREAMS_PATH="${candidate}"
      log DEBUG "Dispatcharr streams endpoint: ${STREAMS_PATH}"
      return 0
    fi
  done

  die "Could not find the Dispatcharr streams endpoint at ${DISPATCHARR_URL} (tried /api/streams/ and /api/channels/streams/)."
}

ensure_channels_path() {
  if [[ -n "${CHANNELS_PATH}" ]]; then
    return 0
  fi

  local candidate
  for candidate in "/api/channels/" "/api/channels/channels/"; do
    if probe_candidate "${candidate}"; then
      CHANNELS_PATH="${candidate}"
      log DEBUG "Dispatcharr channels endpoint: ${CHANNELS_PATH}"
      return 0
    fi
  done

  die "Could not find the Dispatcharr channels endpoint at ${DISPATCHARR_URL} (tried /api/channels/ and /api/channels/channels/)."
}

# ---------------------------------------------------------------------------
# M3U refresh
# ---------------------------------------------------------------------------
fetch_m3u_accounts() {
  api GET "/api/m3u/accounts/"
  jq -c 'if type == "array" then . else (.results // []) end' <<<"${HTTP_BODY}"
}

m3u_refresh_in_progress() {
  jq -r '
    [.[] | select(.is_active == true) | .status]
    | any(. == "fetching" or . == "parsing")
  ' <<<"$1"
}

m3u_accounts_fingerprint() {
  jq -c '
    [.[] | select(.is_active == true) | {id, status, updated_at}]
    | sort_by(.id)
  ' <<<"$1"
}

refresh_m3u() {
  local before after before_fingerprint after_fingerprint message
  local path="/api/m3u/refresh/"
  local started_at=${SECONDS}
  local saw_progress="false"
  local interval=3
  local start_grace=30

  if [[ -n "${M3U_ACCOUNT_ID}" ]]; then
    path="/api/m3u/refresh/${M3U_ACCOUNT_ID}/"
  fi

  before="$(fetch_m3u_accounts)"
  before_fingerprint="$(m3u_accounts_fingerprint "${before}")"

  log INFO "Triggering Dispatcharr M3U refresh (${path})..."
  api POST "${path}"

  message="$(jq -r '.message // empty' <<<"${HTTP_BODY}" 2>/dev/null || true)"
  [[ -n "${message}" ]] && log DEBUG "${message}"

  while :; do
    sleep "${interval}"
    after="$(fetch_m3u_accounts)"

    if [[ "$(m3u_refresh_in_progress "${after}")" == "true" ]]; then
      saw_progress="true"
      log DEBUG "M3U refresh in progress..."
    else
      after_fingerprint="$(m3u_accounts_fingerprint "${after}")"
      if [[ "${saw_progress}" == "true" || "${after_fingerprint}" != "${before_fingerprint}" ]]; then
        log INFO "M3U refresh finished."
        jq -r '
          .[] | select(.is_active == true)
          | "  \(.name): \(.status)\(if .last_message then " - " + (.last_message[0:200]) else "" end)"
        ' <<<"${after}" >&2
        return 0
      fi
    fi

    local elapsed=$((SECONDS - started_at))

    if [[ "${saw_progress}" == "false" && "${elapsed}" -ge "${start_grace}" ]]; then
      die "M3U refresh did not start within ${start_grace}s (is the Dispatcharr celery worker running?)."
    fi

    if ((elapsed >= M3U_REFRESH_TIMEOUT)); then
      die "M3U refresh did not finish within ${M3U_REFRESH_TIMEOUT}s; check Dispatcharr and try again."
    fi
  done
}

# ---------------------------------------------------------------------------
# Dispatcharr operations
# ---------------------------------------------------------------------------
fetch_streams() {
  local ndjson="${TMP_DIR}/streams.ndjson"
  ensure_streams_path
  fetch_paginated "${STREAMS_PATH}" "${ndjson}"

  local total
  total="$(wc -l <"${ndjson}" | tr -d ' ')"
  log INFO "Fetched ${total} stream(s) from Dispatcharr."

  jq -s --argjson limit "${STREAM_LIMIT}" '
    sort_by(.id // 0) | reverse | .[:$limit]
  ' "${ndjson}"
}

get_stream() {
  local stream_id="$1"
  ensure_streams_path
  api GET "${STREAMS_PATH}${stream_id}/"
  jq -c '.' <<<"${HTTP_BODY}"
}

find_channel() {
  ensure_channels_path

  if [[ -n "${CHANNEL_ID}" ]]; then
    api GET "${CHANNELS_PATH}${CHANNEL_ID}/"
    jq -c '.' <<<"${HTTP_BODY}"
    return 0
  fi

  local ndjson="${TMP_DIR}/channels.ndjson"
  fetch_paginated "${CHANNELS_PATH}" "${ndjson}"

  local matches
  matches="$(jq -s --argjson number "${CHANNEL_NUMBER}" '
    [
      .[]
      | select(((.effective_channel_number // .channel_number) // null) == $number)
    ]
  ' "${ndjson}")"

  local count
  count="$(jq 'length' <<<"${matches}")"

  if ((count == 0)); then
    die "No channel found with number ${CHANNEL_NUMBER}. Set DISPATCHARR_CHANNEL_ID to target a channel by id."
  fi

  if ((count > 1)); then
    log ERROR "Multiple channels use number ${CHANNEL_NUMBER}:"
    jq -r '.[] | "  id=\(.id)  name=\(.name)"' <<<"${matches}" >&2
    die "Set DISPATCHARR_CHANNEL_ID to choose one of the channels above."
  fi

  jq -c '.[0]' <<<"${matches}"
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------
format_date() {
  local raw="$1"
  local formatted

  if [[ -z "${raw}" || "${raw}" == "null" ]]; then
    printf 'unknown'
    return 0
  fi

  if formatted="$(date -d "${raw}" '+%Y-%m-%d %H:%M' 2>/dev/null)"; then
    printf '%s' "${formatted}"
  else
    printf '%s' "${raw:0:16}" | tr 'T' ' '
  fi
}

format_channel_number() {
  local number="$1"
  if [[ "${number}" =~ ^([0-9]+)\.0+$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  else
    printf '%s' "${number}"
  fi
}

stream_field() {
  local stream="$1"
  local field="$2"
  jq -r --arg field "${field}" '.[$field] // ""' <<<"${stream}"
}

print_table() {
  local streams="$1"
  local index=0

  printf '%-3s %-8s %-17s %-6s %s\n' "#" "ID" "UPDATED" "STALE" "NAME"
  printf '%-3s %-8s %-17s %-6s %s\n' "---" "--------" "-----------------" "------" "----------------------------------------"

  while IFS= read -r stream; do
    index=$((index + 1))
    local id name updated stale
    id="$(stream_field "${stream}" id)"
    name="$(stream_field "${stream}" name)"
    updated="$(format_date "$(stream_field "${stream}" updated_at)")"
    stale="$(jq -r 'if .is_stale then "yes" else "" end' <<<"${stream}")"

    [[ -n "${name}" ]] || name="(unnamed)"
    printf '%-3s %-8s %-17s %-6s %s\n' \
      "${index}" "${id}" "${updated}" "${stale}" "${name:0:100}"
  done < <(jq -c '.[]' <<<"${streams}")
}

write_entities() {
  local streams="$1"
  local output="$2"
  local tmp="${TMP_DIR}/entities.ndjson"

  : >"${tmp}"

  if [[ "$(jq 'length' <<<"${streams}")" -eq 0 ]]; then
    placeholder_entity_json >"${tmp}"
  else
    while IFS= read -r stream; do
      local id name updated stale label
      id="$(stream_field "${stream}" id)"
      name="$(stream_field "${stream}" name)"
      updated="$(format_date "$(stream_field "${stream}" updated_at)")"
      stale="$(jq -r 'if .is_stale then "stale" else "" end' <<<"${stream}")"
      [[ -n "${name}" ]] || name="(unnamed)"

      label="#${id} · ${name:0:70} · ${updated}"
      jq -nc \
        --arg name "#${id} ${name:0:80}" \
        --arg id "${id}" \
        --arg stream_name "${name}" \
        --arg label "${label}" \
        --arg updated "${updated}" \
        --arg stale "${stale}" \
        '{
          name: $name,
          id: $id,
          stream_name: $stream_name,
          label: $label,
          updated: $updated,
          stale: $stale
        }' >>"${tmp}"
    done < <(jq -c '.[]' <<<"${streams}")
  fi

  mkdir -p "$(dirname "${output}")"

  # Write in place (not mv) so the inode stays stable and OliveTin's fsnotify
  # watcher reloads the entity file immediately, just like fetch-open-prs.sh.
  cat "${tmp}" >"${output}"

  if [[ "$(jq 'length' <<<"${streams}")" -eq 0 ]]; then
    log INFO "No streams found; wrote a placeholder entity to ${output}."
  else
    log INFO "Wrote $(wc -l <"${output}" | tr -d ' ') stream(s) to ${output}."
  fi
}

# ---------------------------------------------------------------------------
# Interactive picker
# ---------------------------------------------------------------------------
select_stream_whiptail() {
  local streams="$1"
  local -a menu=()
  local index=0

  while IFS= read -r stream; do
    index=$((index + 1))
    local id name updated stale
    id="$(stream_field "${stream}" id)"
    name="$(stream_field "${stream}" name)"
    updated="$(format_date "$(stream_field "${stream}" updated_at)")"
    stale="$(jq -r 'if .is_stale then " [stale]" else "" end' <<<"${stream}")"
    [[ -n "${name}" ]] || name="(unnamed)"
    menu+=("${index}" "${id}  ${updated}  ${name:0:60}${stale}")
  done < <(jq -c '.[]' <<<"${streams}")

  menu+=("c" "Cancel - make no changes")

  local choice
  choice="$(whiptail \
    --title "Dispatcharr: channel ${CHANNEL_NUMBER}" \
    --menu "Select the stream to assign to channel ${CHANNEL_NUMBER}:" \
    24 110 14 "${menu[@]}" 3>&1 1>&2 2>&3)" || {
    log INFO "Cancelled - no changes made."
    exit 0
  }

  if [[ "${choice}" == "c" ]]; then
    log INFO "Cancelled - no changes made."
    exit 0
  fi

  SELECTED_STREAM="$(jq -c --argjson index "${choice}" '.[$index - 1]' <<<"${streams}")"
}

select_stream_dialog() {
  local streams="$1"
  local -a menu=()
  local index=0

  while IFS= read -r stream; do
    index=$((index + 1))
    local id name updated stale
    id="$(stream_field "${stream}" id)"
    name="$(stream_field "${stream}" name)"
    updated="$(format_date "$(stream_field "${stream}" updated_at)")"
    stale="$(jq -r 'if .is_stale then " [stale]" else "" end' <<<"${stream}")"
    [[ -n "${name}" ]] || name="(unnamed)"
    menu+=("${index}" "${id}  ${updated}  ${name:0:60}${stale}")
  done < <(jq -c '.[]' <<<"${streams}")

  menu+=("c" "Cancel - make no changes")

  local choice
  choice="$(dialog \
    --stdout \
    --title "Dispatcharr: channel ${CHANNEL_NUMBER}" \
    --menu "Select the stream to assign to channel ${CHANNEL_NUMBER}:" \
    24 110 14 "${menu[@]}")" || {
    log INFO "Cancelled - no changes made."
    exit 0
  }

  if [[ "${choice}" == "c" ]]; then
    log INFO "Cancelled - no changes made."
    exit 0
  fi

  SELECTED_STREAM="$(jq -c --argjson index "${choice}" '.[$index - 1]' <<<"${streams}")"
}

select_stream_text() {
  local streams="$1"
  local count
  count="$(jq 'length' <<<"${streams}")"

  printf '\nNewest %s stream(s) in Dispatcharr:\n\n' "${count}" >&2
  print_table "${streams}" >&2
  printf '%-3s %-8s %-17s %-6s %s\n' "c" "" "" "" "Cancel - make no changes" >&2

  local choice
  while :; do
    read -rp "Select a stream [1-${count}, c to cancel]: " choice || {
      log INFO "Cancelled - no changes made."
      exit 0
    }

    if [[ "${choice}" == "c" || "${choice}" == "C" ]]; then
      log INFO "Cancelled - no changes made."
      exit 0
    fi

    if [[ "${choice}" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= count)); then
      break
    fi

    printf 'Invalid selection: %s\n' "${choice}" >&2
  done

  SELECTED_STREAM="$(jq -c --argjson index "${choice}" '.[$index - 1]' <<<"${streams}")"
}

select_stream() {
  local streams="$1"

  # stdout is a pipe here (the caller captures the selected JSON), so only
  # stdin needs to be a TTY. whiptail/dialog draw on stderr, which is still
  # the terminal; the text picker writes its table to stderr too.
  if [[ ! -t 0 ]]; then
    die "No TTY for the interactive picker. Use --list or --assign <stream_id>."
  fi

  case "${PICKER}" in
    whiptail)
      command -v whiptail >/dev/null 2>&1 || die "DISPATCHARR_PICKER=whiptail but whiptail is not installed."
      [[ -t 2 ]] || die "whiptail needs a terminal on stderr."
      select_stream_whiptail "${streams}"
      ;;
    dialog)
      command -v dialog >/dev/null 2>&1 || die "DISPATCHARR_PICKER=dialog but dialog is not installed."
      [[ -t 2 ]] || die "dialog needs a terminal on stderr."
      select_stream_dialog "${streams}"
      ;;
    text)
      select_stream_text "${streams}"
      ;;
    auto)
      if command -v whiptail >/dev/null 2>&1 && [[ -t 2 ]]; then
        select_stream_whiptail "${streams}"
      elif command -v dialog >/dev/null 2>&1 && [[ -t 2 ]]; then
        select_stream_dialog "${streams}"
      else
        select_stream_text "${streams}"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Assignment
# ---------------------------------------------------------------------------
channel_label() {
  local channel="$1"
  local number
  number="$(jq -r '(.effective_channel_number // .channel_number) // "?"' <<<"${channel}")"
  number="$(format_channel_number "${number}")"
  jq -r --arg number "${number}" '
    "\(.name // "unnamed") (id \(.id), number \($number))"
  ' <<<"${channel}"
}

confirm_assignment() {
  local channel="$1"
  local stream="$2"
  local channel_name stream_id stream_name existing

  channel_name="$(channel_label "${channel}")"
  stream_id="$(jq -r '.id' <<<"${stream}")"
  stream_name="$(jq -r '.name // "(unnamed)"' <<<"${stream}")"
  existing="$(jq -c '.streams // []' <<<"${channel}")"

  if [[ "${ASSUME_YES}" == "true" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "Refusing to modify a channel without confirmation in a non-interactive shell. Pass --yes."
  fi

  printf '\n' >&2
  printf 'Channel : %s\n' "${channel_name}" >&2
  printf 'Stream  : %s (id %s)\n' "${stream_name}" "${stream_id}" >&2
  printf 'Current : %s\n' "${existing}" >&2

  if [[ "${KEEP_EXISTING}" == "true" ]]; then
    printf '\nThe new stream will be tried first; the current streams stay as backups.\n' >&2
  else
    printf '\nThis will REPLACE the channel stream list with the selected stream.\n' >&2
  fi

  local answer
  read -rp "Type 'yes' to continue: " answer
  if [[ "${answer}" != "yes" ]]; then
    log INFO "Cancelled - no changes made."
    exit 0
  fi
}

assign_stream() {
  local channel="$1"
  local stream="$2"

  local channel_id channel_number channel_name
  local stream_id stream_name
  local existing new_streams payload

  channel_id="$(jq -r '.id' <<<"${channel}")"
  channel_number="$(jq -r '(.effective_channel_number // .channel_number) // "?"' <<<"${channel}")"
  channel_number="$(format_channel_number "${channel_number}")"
  channel_name="$(jq -r '.name // "unnamed"' <<<"${channel}")"

  stream_id="$(jq -r '.id' <<<"${stream}")"
  stream_name="$(jq -r '.name // "(unnamed)"' <<<"${stream}")"

  existing="$(jq -c '.streams // []' <<<"${channel}")"

  if [[ "${KEEP_EXISTING}" == "true" ]]; then
    new_streams="$(jq -c --argjson stream_id "${stream_id}" '
      [$stream_id] + [.[] | select(. != $stream_id)]
    ' <<<"${existing}")"
  else
    new_streams="$(jq -c --argjson stream_id "${stream_id}" '[$stream_id]' <<<"${existing}")"
  fi

  payload="$(jq -nc --argjson streams "${new_streams}" '{streams: $streams}')"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log INFO "DRY RUN: PATCH /api/channels/${channel_id}/ ${payload}"
    log INFO "DRY RUN: would assign stream ${stream_id} \"${stream_name}\" to channel ${channel_number} \"${channel_name}\"."
    return 0
  fi

  ensure_channels_path
  api PATCH "${CHANNELS_PATH}${channel_id}/" "${payload}"

  if ! jq -e --argjson stream_id "${stream_id}" '
    (.streams // []) | index($stream_id) != null
  ' <<<"${HTTP_BODY}" >/dev/null 2>&1; then
    die "Dispatcharr accepted the PATCH but its response does not list stream ${stream_id}."
  fi

  log INFO "SUCCESS: channel ${channel_number} \"${channel_name}\" (id ${channel_id}) now uses stream ${stream_id} \"${stream_name}\"."
  if [[ "${KEEP_EXISTING}" == "true" ]]; then
    log INFO "Stream list is now ${new_streams} (new stream first, existing streams kept as backups)."
  else
    log INFO "Previous stream list ${existing} was replaced."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  case "${MODE}" in
    list)
      if [[ "${REFRESH_M3U}" == "true" ]]; then
        refresh_m3u
      fi

      local streams
      streams="$(fetch_streams)"

      case "${FORMAT}" in
        table)
          if [[ -n "${OUTPUT}" ]]; then
            mkdir -p "$(dirname "${OUTPUT}")"
            print_table "${streams}" >"${OUTPUT}"
            log INFO "Wrote stream table to ${OUTPUT}."
          else
            print_table "${streams}"
          fi
          ;;
        json)
          if [[ -n "${OUTPUT}" ]]; then
            mkdir -p "$(dirname "${OUTPUT}")"
            jq '.' <<<"${streams}" >"${OUTPUT}"
            log INFO "Wrote stream JSON to ${OUTPUT}."
          else
            jq '.' <<<"${streams}"
          fi
          ;;
        entities)
          write_entities "${streams}" "${OUTPUT:-${ENTITY_FILE}}"
          ;;
      esac
      ;;

    assign)
      [[ "${STREAM_ID}" =~ ^[0-9]+$ ]] || die "--assign requires a numeric stream id."
      if [[ "${REFRESH_M3U}" == "true" ]]; then
        log WARN "--refresh is ignored with --assign; use the list action to refresh the picker."
      fi
      local channel stream
      channel="$(find_channel)"
      stream="$(get_stream "${STREAM_ID}")"
      confirm_assignment "${channel}" "${stream}"
      assign_stream "${channel}" "${stream}"
      ;;

    interactive)
      local channel streams
      if [[ "${REFRESH_M3U}" == "true" ]]; then
        refresh_m3u
      fi
      channel="$(find_channel)"
      streams="$(fetch_streams)"
      select_stream "${streams}"
      [[ -n "${SELECTED_STREAM}" ]] || die "The picker returned no stream."
      confirm_assignment "${channel}" "${SELECTED_STREAM}"
      assign_stream "${channel}" "${SELECTED_STREAM}"
      ;;
  esac
}

main "$@"
