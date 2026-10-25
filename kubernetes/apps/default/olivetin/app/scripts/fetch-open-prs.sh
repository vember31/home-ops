#!/usr/bin/env bash
#
# Write OliveTin entity data for the open pull requests of a GitHub repository.
#
# This powers the "Pull Requests" dashboard: one card per open PR, showing the
# PR description with GitHub's own markdown/HTML rendering, and a per-PR merge
# button. It is run:
#   - on startup and on a cron schedule (see the "Refresh Open PR List" action)
#   - after merge-open-prs.sh merges anything
#
# GitHub's GraphQL API is used because it exposes `bodyHTML` - the PR body
# already rendered from markdown to sanitised HTML - so the dashboard can show
# bold text, links, code blocks, tables, etc. without shipping a markdown parser
# in this script.
#
# Environment:
#   GITHUB_TOKEN              required - PAT with pull request read access
#   GITHUB_REPO               owner/repo (default: vember31/home-ops)
#   GITHUB_API_URL            API base URL override (for GitHub Enterprise)
#   GITHUB_GRAPHQL_URL        GraphQL URL override (default: ${GITHUB_API_URL}/graphql,
#                             with /api/v3 rewritten to /api/graphql for GHES)
#   OLIVETIN_PR_ENTITY_FILE   output file (default: /tmp/olivetin-entities/prs.json)
#   MAX_CHANGELOG_CHARS       max rendered changelog HTML per PR (default: 8000)

set -euo pipefail

REPO="${GITHUB_REPO:-vember31/home-ops}"
API="${GITHUB_API_URL:-https://api.github.com}"
API="${API%/}"
if [[ -n "${GITHUB_GRAPHQL_URL:-}" ]]; then
  GRAPHQL="${GITHUB_GRAPHQL_URL}"
elif [[ "${API}" == "https://api.github.com" ]]; then
  GRAPHQL="${API}/graphql"
else
  GRAPHQL="${API%/v3}/graphql"
fi
ENTITY_FILE="${OLIVETIN_PR_ENTITY_FILE:-/tmp/olivetin-entities/prs.json}"
MAX_CHANGELOG_CHARS="${MAX_CHANGELOG_CHARS:-8000}"

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

if ! [[ "${MAX_CHANGELOG_CHARS}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: MAX_CHANGELOG_CHARS must be a number (got: ${MAX_CHANGELOG_CHARS})" >&2
  exit 1
fi

repo_owner="${REPO%%/*}"
repo_name="${REPO#*/}"

query='query($owner: String!, $repo: String!) {
  repository(owner: $owner, name: $repo) {
    pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: DESC}) {
      totalCount
      nodes {
        number
        title
        url
        isDraft
        updatedAt
        headRefName
        author {
          __typename
          login
        }
        labels(first: 50) {
          nodes {
            name
          }
        }
        bodyHTML
      }
    }
  }
}'

payload="$(jq -cn \
  --arg query "${query}" \
  --arg owner "${repo_owner}" \
  --arg repo "${repo_name}" \
  '{query: $query, variables: {owner: $owner, repo: $repo}}')"

if ! prs="$(curl -fsSL --retry 2 --retry-delay 2 \
  -H "Accept: application/json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "${payload}" \
  "${GRAPHQL}")"; then
  echo "ERROR: could not list open PRs for ${REPO} - check repository name and token permissions." >&2
  exit 1
fi

if ! total="$(jq -er '.data.repository.pullRequests.totalCount' <<<"${prs}" 2>/dev/null)"; then
  message="$(jq -r '.errors[0].message // "unexpected response"' <<<"${prs}" 2>/dev/null || echo "unexpected response")"
  echo "ERROR: GitHub GraphQL query failed for ${REPO}: ${message}" >&2
  exit 1
fi

if [[ "${total}" -ge 100 ]]; then
  echo "WARNING: GitHub returned 100 open PRs (its page limit) - only the first 100 are shown." >&2
fi

# Changelog bodies are HTML rendered by GitHub (and sanitised by GitHub), which
# the dashboard inserts into a display component. Written as one JSON object per
# line (the NDJSON format OliveTin reads from .json entity files).
mkdir -p "$(dirname "${ENTITY_FILE}")"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

jq -c --argjson max "${MAX_CHANGELOG_CHARS}" '
  # Append closing tags for anything left open by the truncation, so a cut in
  # the middle of a tag cannot swallow the rest of the dashboard card.
  def close_open_tags:
    [scan("<[^>]+>")]
    | reduce .[] as $tag ({stack: []};
        ($tag | capture("^<\\s*(?<close>/?)\\s*(?<name>[A-Za-z][A-Za-z0-9-]*)")) as $match
        | if $match == null then .
          elif ($tag | endswith("/>")) then .
          elif (["br", "hr", "img", "input", "meta", "link", "source", "wbr",
                 "area", "base", "col", "embed", "param", "track"]
                | index($match.name | ascii_downcase)) != null then .
          elif $match.close == "/" then
            .stack |= (if (.[-1] // "") == ($match.name | ascii_downcase)
                       then .[0:-1] else . end)
          else .stack += [($match.name | ascii_downcase)]
          end)
    | .stack
    | reverse
    | map("</" + . + ">")
    | join("");

  # Truncate on an HTML boundary rather than in the middle of a tag/entity.
  # Prefer the last closing block element so the card does not end mid-table or
  # mid-list.
  def truncate_html($max):
    . as $html
    | if ($html | length) <= $max then $html
      else
        ($html[0:$max]
          | sub("<[^>]*$"; "")
          | sub("&[A-Za-z0-9#]*$"; "")) as $cut
        | ([$cut | match("</(p|li|tr|h[1-6]|details|summary|ul|ol|blockquote|pre|table|div)>"; "g")]
            | last
            | if . == null then null else (.offset + (.string | length)) end) as $boundary
        | (if $boundary != null and $boundary > ($max / 2)
            then $cut[0:$boundary]
            else $cut
            end) as $truncated
        | $truncated
          + ($truncated | close_open_tags)
          + "\n<p><em>... truncated - open the PR for the full changelog</em></p>"
      end;

  def clean_body:
    gsub("<!--[\\s\\S]*?-->"; "")
    | sub("(?i)<h[1-6][^>]*>\\s*Configuration\\s*</h[1-6]>[\\s\\S]*$"; "");

  # GraphQL reports bot logins without the `[bot]` suffix used by the REST API;
  # keep the familiar GitHub login so metadata matches the merge action filters.
  def author_login:
    if .author == null then ""
    elif .author.__typename == "Bot" then ((.author.login // "") + "[bot]")
    else (.author.login // "")
    end;

  (.data.repository.pullRequests.nodes // [])
  | map(select(.isDraft == false))
  | .[]
  | (author_login) as $author
  | {
      name: ("#" + (.number | tostring) + " " + ((.title // "")[0:90])),
      number: (.number | tostring),
      title: (.title // ""),
      author: $author,
      url: (.url // ""),
      branch: (.headRefName // ""),
      labels: ([.labels.nodes[]?.name] | join(", ")),
      updated: ((.updatedAt // "")[0:10]),
      card_title: ("#" + (.number | tostring) + " " + (.title // "")),
      meta: (" · @" + $author + " · updated " + ((.updatedAt // "")[0:10])
             + (if ([.labels.nodes[]?.name] | length) > 0
                then " · " + ([.labels.nodes[]?.name] | join(", "))
                else "" end)),
      action_label: ("Merge PR #" + (.number | tostring)),
      action_shell: ("/scripts/merge-open-prs.sh --mode merge --pr " + (.number | tostring) + " --delete-branches"),
      changelog: ((.bodyHTML // "") | clean_body | truncate_html($max))
    }
' <<<"${prs}" > "${tmp}"

shown="$(wc -l < "${tmp}" | tr -d ' ')"

if [[ "${shown}" -eq 0 ]]; then
  # OliveTin warns about empty entity files / entity actions with no instances,
  # so when there is nothing to merge leave a placeholder card in place.
  cat > "${tmp}" <<'PLACEHOLDER'
{"name":"No open PRs","number":"","title":"No open pull requests 🎉","author":"","url":"https://github.com/vember31/home-ops/pulls","branch":"","labels":"","updated":"","card_title":"No open pull requests 🎉","meta":"","action_label":"Refresh Open PRs","action_shell":"/scripts/fetch-open-prs.sh","changelog":"<p>There are no open pull requests right now.</p><p>The list refreshes automatically every 5 minutes, or click Refresh Open PRs below.</p>"}
PLACEHOLDER
fi

# Keep the inode stable and write in place so OliveTin (fsnotify) reloads the
# entity file immediately. The temp file avoids leaving a truncated file behind
# if jq fails partway through.
cat "${tmp}" > "${ENTITY_FILE}"

if [[ "${shown}" -eq 0 ]]; then
  echo "No open PRs - wrote placeholder card (${total} open, drafts skipped) to ${ENTITY_FILE}"
else
  echo "Wrote ${shown} open PRs (${total} open, drafts skipped) to ${ENTITY_FILE}"
fi
echo "OliveTin will reload the Pull Requests dashboard automatically."
