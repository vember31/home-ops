#!/usr/bin/env bash
#
# Merge open pull requests on a GitHub repository.
#
# This script is started by OliveTin, which passes the action arguments as
# environment variables (MERGE_MODE, PR_AUTHOR, REQUIRED_LABEL, MERGE_METHOD,
# DELETE_BRANCH). It can also be run manually:
#
#   GITHUB_TOKEN=github_pat_... MERGE_MODE=preview ./merge-open-prs.sh
#   GITHUB_TOKEN=github_pat_... ./merge-open-prs.sh --mode merge --pr 4827
#
# The token needs write access to pull requests, and - when deleting branches -
# to repository contents ("Pull requests" + "Contents" for fine-grained PATs,
# or the "repo" scope for classic PATs).
#
# After any successful merge run, the OliveTin PR dashboard entities are
# refreshed (best effort) by calling fetch-open-prs.sh, if it is available.
#
# Exit code is 0 for a completed run (including bulk runs where individual PRs
# could not be merged - see the summary), and 1 for authentication,
# configuration or network setup failures - or when a single requested PR
# could not be merged.

set -euo pipefail

REPO="${GITHUB_REPO:-vember31/home-ops}"
API="${GITHUB_API_URL:-https://api.github.com}"
MODE="${MERGE_MODE:-preview}"
AUTHOR="${PR_AUTHOR:-any}"
LABEL="${REQUIRED_LABEL:-any}"
METHOD="${MERGE_METHOD:-squash}"
DELETE_BRANCH="${DELETE_BRANCH:-}"
PR_NUMBER=""
FETCH_SCRIPT="${OLIVETIN_FETCH_SCRIPT:-/scripts/fetch-open-prs.sh}"

usage() {
  cat <<'EOF'
Merge open pull requests on a GitHub repository.

Usage: merge-open-prs.sh [options]

Options:
  --mode preview|merge          preview only (default) or actually merge
  --pr NUMBER                   merge exactly this PR (overrides --author/--label)
  --author LOGIN|any            only merge PRs opened by LOGIN (default: any)
  --label LABEL|any             only merge PRs carrying LABEL (default: any)
  --method squash|merge|rebase  merge method to use (default: squash)
  --delete-branches             delete the head branch after a successful merge
  --repo OWNER/REPO             repository (default: vember31/home-ops)
  -h, --help                    show this help

Environment variables (how OliveTin invokes this script; used as defaults):
  GITHUB_TOKEN       required - PAT with pull request + contents write access
  MERGE_MODE         preview (default) or merge
  PR_AUTHOR          PR author login, or "any"
  REQUIRED_LABEL     label that a PR must carry, or "any"
  MERGE_METHOD       squash (default), merge or rebase
  DELETE_BRANCH      non-empty enables branch deletion after merging
  GITHUB_REPO        owner/repo override
  GITHUB_API_URL     API base URL override (for GitHub Enterprise)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --method) METHOD="$2"; shift 2 ;;
    --delete-branches) DELETE_BRANCH="--delete-branches"; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

case "${MODE}" in
  preview|merge) ;;
  *) echo "ERROR: MERGE_MODE must be 'preview' or 'merge' (got: ${MODE})" >&2; exit 1 ;;
esac

case "${METHOD}" in
  squash|merge|rebase) ;;
  *) echo "ERROR: MERGE_METHOD must be 'squash', 'merge' or 'rebase' (got: ${METHOD})" >&2; exit 1 ;;
esac

if ! [[ "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "ERROR: GITHUB_REPO must look like 'owner/repo' (got: ${REPO})" >&2
  exit 1
fi

if [[ -n "${PR_NUMBER}" ]] && ! [[ "${PR_NUMBER}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --pr must be a PR number (got: ${PR_NUMBER})" >&2
  exit 1
fi

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: ${tool}" >&2
    exit 1
  fi
done

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN is not set." >&2
  echo "Add a GitLab CI/CD variable 'github' containing {\"GITHUB_TOKEN\": \"github_pat_...\"} so External Secrets can mount it." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

accept_header="Accept: application/vnd.github+json"
version_header="X-GitHub-Api-Version: 2022-11-28"
auth_header="Authorization: Bearer ${GITHUB_TOKEN}"

merged=0
failed=0
preview_ready=0
preview_not_ready=0
preview_unknown=0
PREVIEW_NOTE=""

api_get() {
  curl -fsSL --retry 2 --retry-delay 2 \
    -H "${accept_header}" -H "${version_header}" -H "${auth_header}" \
    "${API}$1"
}

merge_pr() {
  # Prints the HTTP status code and leaves the response body in ${TMP}/merge.json.
  curl -sSL \
    -X PUT \
    -H "${accept_header}" -H "${version_header}" -H "${auth_header}" \
    -H "Content-Type: application/json" \
    -d "{\"merge_method\":\"${METHOD}\"}" \
    -o "${TMP}/merge.json" -w '%{http_code}' \
    "${API}/repos/${REPO}/pulls/$1/merge"
}

delete_branch() {
  # Prints the HTTP status code and leaves the response body in ${TMP}/delete.json.
  local ref
  ref="$(jq -rn --arg branch "$1" '$branch|@uri')"
  curl -sSL --retry 2 --retry-delay 2 \
    -X DELETE \
    -H "${accept_header}" -H "${version_header}" -H "${auth_header}" \
    -o "${TMP}/delete.json" -w '%{http_code}' \
    "${API}/repos/${REPO}/git/refs/heads/${ref}"
}

preview_fetch_state() {
  # Prints the mergeable_state for a PR. GitHub computes mergeability lazily,
  # so the first fetch often returns "unknown" - retry a couple of times.
  local number="$1" state="unknown" detail="" attempt
  for attempt in 1 2 3; do
    if ! detail="$(api_get "/repos/${REPO}/pulls/${number}")"; then
      return 1
    fi
    state="$(jq -r '.mergeable_state // "unknown"' <<<"${detail}")"
    if [[ "${state}" != "unknown" ]]; then
      break
    fi
    if [[ "${attempt}" -lt 3 ]]; then
      sleep 2
    fi
  done
  echo "${state}"
}

preview_state_note() {
  # Sets PREVIEW_NOTE for the given mergeable_state and updates the counters.
  # (Must run in the main shell - command substitution would lose the counters.)
  case "$1" in
    clean) PREVIEW_NOTE="looks mergeable"; preview_ready=$((preview_ready + 1)) ;;
    unstable) PREVIEW_NOTE="mergeable, but checks are pending or failing"; preview_ready=$((preview_ready + 1)) ;;
    blocked) PREVIEW_NOTE="blocked by required checks/reviews"; preview_not_ready=$((preview_not_ready + 1)) ;;
    dirty) PREVIEW_NOTE="has merge conflicts"; preview_not_ready=$((preview_not_ready + 1)) ;;
    behind) PREVIEW_NOTE="branch is behind the base branch"; preview_ready=$((preview_ready + 1)) ;;
    unknown) PREVIEW_NOTE="GitHub has not calculated mergeability yet - merge mode will still attempt it"; preview_unknown=$((preview_unknown + 1)) ;;
    *) PREVIEW_NOTE="$1"; preview_not_ready=$((preview_not_ready + 1)) ;;
  esac
}

attempt_merge() {
  # $1 number, $2 title, $3 author, $4 branch, $5 fork
  local number="$1" title="$2" author="$3" branch="$4" fork="$5" code message dcode

  echo "#${number} ${title} (@${author})"

  code="$(merge_pr "${number}")" || code="000"

  if [[ "${code}" == "200" ]] && [[ "$(jq -r '.merged // false' "${TMP}/merge.json" 2>/dev/null)" == "true" ]]; then
    echo "  -> merged ($(jq -r '.sha // "?"' "${TMP}/merge.json"))"
    merged=$((merged + 1))
    if [[ -n "${DELETE_BRANCH}" ]]; then
      if [[ "${fork}" == "true" ]]; then
        echo "     branch not deleted (PR comes from a fork)"
      else
        dcode="$(delete_branch "${branch}")" || dcode="000"
        case "${dcode}" in
          204) echo "     deleted branch ${branch}" ;;
          404|422) echo "     branch ${branch} was already deleted" ;;
          *) echo "     WARNING: could not delete branch ${branch} (HTTP ${dcode})" ;;
        esac
      fi
    fi
    return 0
  fi

  if [[ "${code}" == "401" ]]; then
    echo "ERROR: GitHub rejected the token mid-run (HTTP 401) - aborting." >&2
    exit 1
  fi

  message="$(jq -r '.message // "unknown error"' "${TMP}/merge.json" 2>/dev/null || echo "no response body")"
  echo "  -> NOT merged (HTTP ${code}): ${message}"
  failed=$((failed + 1))
  return 1
}

refresh_entities() {
  # Update the OliveTin PR dashboard (best effort) after merge runs.
  if [[ "${MODE}" != "merge" ]]; then
    return 0
  fi
  if [[ -x "${FETCH_SCRIPT}" ]]; then
    "${FETCH_SCRIPT}" >/dev/null 2>&1 || true
  fi
}

echo "GitHub merge run - $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Repository:   ${REPO}"
echo "Mode:         ${MODE}"
if [[ -n "${PR_NUMBER}" ]]; then
  echo "PR:           #${PR_NUMBER}"
else
  echo "Filters:      author=${AUTHOR}, label=${LABEL}"
fi
echo "Merge method: ${METHOD}"
if [[ -n "${DELETE_BRANCH}" ]]; then
  echo "Branches:     delete after merge"
fi
echo

if ! me="$(api_get /user 2>"${TMP}/curl-error")"; then
  echo "ERROR: could not authenticate with GitHub - check GITHUB_TOKEN." >&2
  cat "${TMP}/curl-error" >&2 || true
  exit 1
fi
echo "Authenticated as $(jq -r '.login // "unknown"' <<<"${me}")"

# ---------------------------------------------------------------------------
# Single PR mode (used by the per-PR merge buttons on the dashboard).
# ---------------------------------------------------------------------------
if [[ -n "${PR_NUMBER}" ]]; then
  if ! detail="$(api_get "/repos/${REPO}/pulls/${PR_NUMBER}")"; then
    echo "ERROR: could not fetch PR #${PR_NUMBER} from ${REPO} - does it exist?" >&2
    exit 1
  fi

  title="$(jq -r '.title // ""' <<<"${detail}")"
  author="$(jq -r '.user.login // ""' <<<"${detail}")"
  state="$(jq -r '.state // "unknown"' <<<"${detail}")"
  draft="$(jq -r '.draft // false' <<<"${detail}")"
  branch="$(jq -r '.head.ref // ""' <<<"${detail}")"
  fork="$(jq -r '.head.repo.fork // false' <<<"${detail}")"

  if [[ "${draft}" == "true" ]]; then
    echo "PR #${PR_NUMBER} is a draft - not merging." >&2
    exit 1
  fi
  if [[ "${state}" != "open" ]]; then
    echo "PR #${PR_NUMBER} is not open (state: ${state}) - nothing to do." >&2
    exit 1
  fi

  if [[ "${MODE}" == "preview" ]]; then
    mstate="$(jq -r '.mergeable_state // "unknown"' <<<"${detail}")"
    echo "#${PR_NUMBER} ${title} (@${author})"
    preview_state_note "${mstate}"
    echo "  -> would merge (${mstate}): ${PREVIEW_NOTE}"
    exit 0
  fi

  attempt_merge "${PR_NUMBER}" "${title}" "${author}" "${branch}" "${fork}" || true
  refresh_entities

  if [[ "${failed}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Bulk mode: every open PR matching the selected filters.
# ---------------------------------------------------------------------------
if ! prs="$(api_get "/repos/${REPO}/pulls?state=open&per_page=100&sort=created&direction=asc")"; then
  echo "ERROR: could not list open PRs for ${REPO} - check repository name and token permissions." >&2
  exit 1
fi

scanned="$(jq 'length' <<<"${prs}")"
if [[ "${scanned}" -eq 0 ]]; then
  echo
  echo "No open pull requests - nothing to do."
  exit 0
fi
if [[ "${scanned}" -ge 100 ]]; then
  echo "WARNING: GitHub returned 100 open PRs (its page limit) - only the first 100 were considered."
fi

matches="$(jq -c \
  --arg author "${AUTHOR}" --arg label_filter "${LABEL}" '
    [
      .[]
      | select(.draft == false)
      | select($author == "any" or .user.login == $author)
      | select($label_filter == "any" or ([.labels[].name] | index($label_filter)) != null)
      | {number, title, author: .user.login, branch: .head.ref, fork: (.head.repo.fork // false)}
    ]' <<<"${prs}")"
matched="$(jq 'length' <<<"${matches}")"

echo "Open PRs: ${scanned}, matching filters: ${matched}"
echo

while IFS= read -r pr; do
  [[ -z "${pr}" ]] && continue

  number="$(jq -r '.number' <<<"${pr}")"
  title="$(jq -r '.title' <<<"${pr}")"
  author="$(jq -r '.author' <<<"${pr}")"
  branch="$(jq -r '.branch' <<<"${pr}")"
  fork="$(jq -r '.fork' <<<"${pr}")"

  if [[ "${MODE}" == "preview" ]]; then
    echo "#${number} ${title} (@${author})"
    if ! state="$(preview_fetch_state "${number}")"; then
      echo "  -> could not fetch PR details"
      failed=$((failed + 1))
      continue
    fi
    preview_state_note "${state}"
    echo "  -> would merge (${state}): ${PREVIEW_NOTE}"
    continue
  fi

  attempt_merge "${number}" "${title}" "${author}" "${branch}" "${fork}" || true
done < <(jq -c '.[]' <<<"${matches}")

refresh_entities

echo
echo "Summary"
echo "-------"
echo "Repository:   ${REPO}"
echo "Mode:         ${MODE}"
echo "Filters:      author=${AUTHOR}, label=${LABEL}"
echo "Merge method: ${METHOD}"
echo "Open PRs:     ${scanned}"
echo "Matched:      ${matched}"
echo "Skipped:      $((scanned - matched)) (drafts or filtered out)"
if [[ "${MODE}" == "preview" ]]; then
  echo "Ready:        ${preview_ready}"
  echo "Not ready:    ${preview_not_ready}"
  if [[ "${preview_unknown}" -gt 0 ]]; then
    echo "Unknown:      ${preview_unknown} (GitHub has not calculated mergeability yet)"
  fi
  if [[ "${failed}" -gt 0 ]]; then
    echo "Errors:       ${failed} (could not fetch PR details)"
  fi
  echo
  echo "Preview only - nothing was merged. Re-run with mode 'merge' to apply."
else
  echo "Merged:       ${merged}"
  echo "Not merged:   ${failed}"
fi
echo "Started by:   ${OT_USERNAME:-manual} (execution ${OT_EXECUTIONTRACKINGID:-n/a})"
