#!/usr/bin/env bash
#
# Write OliveTin entity data for the open pull requests of a GitHub repository.
#
# This powers the "Pull Requests" dashboard: one card per open PR, showing a
# cleaned-up changelog and a per-PR merge button. It is run:
#   - on startup and on a cron schedule (see the "Refresh Open PR List" action)
#   - after merge-open-prs.sh merges anything
#
# Environment:
#   GITHUB_TOKEN              required - PAT with pull request read access
#   GITHUB_REPO               owner/repo (default: vember31/home-ops)
#   GITHUB_API_URL            API base URL override (for GitHub Enterprise)
#   OLIVETIN_PR_ENTITY_FILE   output file (default: /tmp/olivetin-entities/prs.json)

set -euo pipefail

REPO="${GITHUB_REPO:-vember31/home-ops}"
API="${GITHUB_API_URL:-https://api.github.com}"
ENTITY_FILE="${OLIVETIN_PR_ENTITY_FILE:-/tmp/olivetin-entities/prs.json}"
MAX_CHANGELOG_CHARS="${MAX_CHANGELOG_CHARS:-3500}"

for tool in curl jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: ${tool}" >&2
    exit 1
  fi
done

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: GITHUB_TOKEN is not set." >&2
  exit 1
fi

if ! [[ "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "ERROR: GITHUB_REPO must look like 'owner/repo' (got: ${REPO})" >&2
  exit 1
fi

if ! prs="$(curl -fsSL --retry 2 --retry-delay 2 \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  "${API}/repos/${REPO}/pulls?state=open&per_page=100&sort=created&direction=desc")"; then
  echo "ERROR: could not list open PRs for ${REPO} - check repository name and token permissions." >&2
  exit 1
fi

total="$(jq 'length' <<<"${prs}")"
if [[ "${total}" -ge 100 ]]; then
  echo "WARNING: GitHub returned 100 open PRs (its page limit) - only the first 100 are shown." >&2
fi

# Changelog text is displayed as raw HTML in a <pre> block, so tags are stripped
# and anything angle-bracket-ish is escaped. Written as one JSON object per line
# (the NDJSON format OliveTin reads from .json entity files).
mkdir -p "$(dirname "${ENTITY_FILE}")"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

jq -c --argjson max "${MAX_CHANGELOG_CHARS}" '
  def clean_changelog:
    gsub("<!--[\\s\\S]*?-->"; "")
    | gsub("### Configuration[\\s\\S]*$"; "")
    | gsub("<[^>]*>"; "")
    | gsub("(?m)^#{1,6}[ \\t]*"; "")
    | gsub("(?m)^---[ \\t]*$"; "")
    | gsub("(?<label>\\[[^\\]]+\\])\\([^)]*\\)"; "\(.label)")
    | gsub("\\[(?<text>[^\\]]+)\\]"; "\(.text)")
    | gsub("`(?<code>[^`]*)`"; "\(.code)")
    | gsub("&#[0-9]+;"; "")
    | gsub("&amp;"; "&")
    | gsub("&lt;"; "<")
    | gsub("&gt;"; ">")
    | gsub("&quot;"; "\"")
    | gsub("[ \\t]+\\n"; "\n")
    | gsub("\\n{3,}"; "\n\n")
    | sub("(\\n|\\s)+$"; "")
    | (if length > $max then (.[0:$max] + "\n\n... truncated - open the PR for the full changelog") else . end)
    | gsub("&"; "&amp;")
    | gsub("<"; "&lt;")
    | gsub(">"; "&gt;");

  .[]
  | select(.draft == false)
  | {
      name: ("#" + (.number | tostring) + " " + ((.title // "")[0:90])),
      number: (.number | tostring),
      title: (.title // ""),
      author: (.user.login // ""),
      url: (.html_url // ""),
      branch: (.head.ref // ""),
      labels: ([.labels[].name] | join(", ")),
      updated: ((.updated_at // "")[0:10]),
      changelog: ((.body // "") | clean_changelog)
    }
' <<<"${prs}" > "${tmp}"

# Keep the inode stable and write in place so OliveTin (fsnotify) reloads the
# entity file immediately. The temp file avoids leaving a truncated file behind
# if jq fails partway through.
cat "${tmp}" > "${ENTITY_FILE}"

shown="$(wc -l < "${ENTITY_FILE}" | tr -d ' ')"
echo "Wrote ${shown} open PRs (${total} open, drafts skipped) to ${ENTITY_FILE}"
echo "OliveTin will reload the Pull Requests dashboard automatically."
