#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/merge-open-prs.sh [--repo OWNER/REPO] [--method squash|merge|rebase] [--dry-run]

Merges every open pull request from oldest to newest.

Options:
  --repo     GitHub repository to operate on. Defaults to vember31/home-ops.
  --method   Merge method to use. Defaults to squash.
  --dry-run  Print the PRs that would be merged without merging them.
  -h, --help Show this help text.
EOF
}

repo="vember31/home-ops"
method="squash"
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --method)
      method="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$method" in
  squash|merge|rebase) ;;
  *)
    echo "Invalid merge method: $method" >&2
    exit 1
    ;;
esac

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required but was not found in PATH" >&2
  exit 1
fi

pr_list_file="$(mktemp)"
trap 'rm -f "$pr_list_file"' EXIT

if ! gh pr list \
  --repo "$repo" \
  --state open \
  --limit 1000 \
  --json number,createdAt \
  --jq 'sort_by(.createdAt, .number) | .[].number' \
  >"$pr_list_file"; then
  echo "Failed to list open PRs for $repo." >&2
  exit 1
fi

mapfile -t prs <"$pr_list_file"

if [[ ${#prs[@]} -eq 0 ]]; then
  echo "No open PRs found for $repo."
  exit 0
fi

echo "Found ${#prs[@]} open PR(s) for $repo."

merge_flag="--$method"
for pr in "${prs[@]}"; do
  if [[ "$dry_run" == true ]]; then
    echo "Would merge #$pr with $method"
    continue
  fi

  echo "Merging #$pr with $method"
  gh pr merge "$pr" --repo "$repo" "$merge_flag"
done
