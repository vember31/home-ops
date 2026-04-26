#!/bin/bash

# Finds and optionally removes folders under a media directory that contain
# no video files (they may have subtitles, nfo, etc. but no actual video).
# Supports running locally or over SSH with user/password (requires sshpass).
#
# Scans two levels deep:
#   - If a top-level folder (show/movie) has no video anywhere inside, delete the whole thing.
#   - If a top-level folder has some video, scan its subfolders (seasons) and delete empty ones.
#
# Usage:
#   ./clean-empty-media-folders.sh [OPTIONS] [/path/to/media]
#
# Options:
#   --delete              Remove folders without video files (default: report only)
#   --host <host>         SSH host (IP or hostname)
#   --user <user>         SSH username
#   --password <pass>     SSH password (requires sshpass to be installed)
#
# Examples:
#   ./clean-empty-media-folders.sh                                                      # local, report
#   ./clean-empty-media-folders.sh --delete /media                                      # local, delete
#   ./clean-empty-media-folders.sh --host 192.168.2.9 --user root /export/media        # SSH, report
#   ./clean-empty-media-folders.sh --host 192.168.2.9 --user root --delete /export/media

DELETE=false
MEDIA_DIR="/media"
SSH_HOST=""
SSH_USER=""
SSH_PASS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete)   DELETE=true;      shift ;;
    --host)     SSH_HOST="$2";    shift 2 ;;
    --user)     SSH_USER="$2";    shift 2 ;;
    --password) SSH_PASS="$2";    shift 2 ;;
    *)          MEDIA_DIR="$1";   shift ;;
  esac
done

# --- SSH setup ---
USE_SSH=false
if [ -n "$SSH_HOST" ]; then
  USE_SSH=true

  if [ -z "$SSH_USER" ]; then
    echo "Error: --user is required when --host is specified."
    exit 1
  fi

  SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=no"

  if [ -n "$SSH_PASS" ]; then
    if ! command -v sshpass &>/dev/null; then
      echo "Error: sshpass is not installed. Install it or use SSH key auth (omit --password)."
      exit 1
    fi
    SSH_CMD="sshpass -p '$SSH_PASS' ssh $SSH_OPTS ${SSH_USER}@${SSH_HOST}"
  else
    SSH_CMD="ssh $SSH_OPTS ${SSH_USER}@${SSH_HOST}"
  fi
fi

# Wrap a command to run locally or over SSH
run() {
  if [ "$USE_SSH" = true ]; then
    eval "$SSH_CMD \"$1\""
  else
    eval "$1"
  fi
}

# --- Validate media dir exists ---
if ! run "[ -d '$MEDIA_DIR' ]"; then
  echo "Error: directory '$MEDIA_DIR' does not exist${USE_SSH:+ on ${SSH_USER}@${SSH_HOST}}."
  exit 1
fi

# --- Main logic (runs as a single remote script if SSH) ---
SCRIPT=$(cat <<'REMOTE'
DELETE=__DELETE__
MEDIA_DIR="__MEDIA_DIR__"

VIDEO_EXTENSIONS=(
  "*.mp4" "*.mkv" "*.avi" "*.mov" "*.wmv"
  "*.m4v" "*.ts"  "*.flv" "*.webm"
  "*.mpg" "*.mpeg" "*.iso"
)

has_video() {
  local dir="$1"
  for ext in "${VIDEO_EXTENSIONS[@]}"; do
    if find "$dir" -type f -iname "$ext" -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  done
  return 1
}

echo "Scanning: $MEDIA_DIR"
echo "Mode: $( [ "$DELETE" = true ] && echo "DELETE" || echo "report only" )"
echo "---"

removed=0
would_remove=0

while IFS= read -r top_dir; do
  if ! has_video "$top_dir"; then
    # No video anywhere in this show/movie folder — remove the whole thing
    echo "[whole folder] $top_dir"
    if [ "$DELETE" = true ]; then
      rm -rf "$top_dir"
      (( removed++ ))
    else
      (( would_remove++ ))
    fi
  else
    # Has video somewhere — check each subfolder (season) individually
    while IFS= read -r sub_dir; do
      if ! has_video "$sub_dir"; then
        echo "[empty subfolder] $sub_dir"
        if [ "$DELETE" = true ]; then
          rm -rf "$sub_dir"
          (( removed++ ))
        else
          (( would_remove++ ))
        fi
      fi
    done < <(find "$top_dir" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
done < <(find "$MEDIA_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

echo "---"
if [ "$DELETE" = true ]; then
  echo "Removed $removed folder(s)."
else
  echo "Found $would_remove folder(s) with no video files. Run with --delete to remove them."
fi
REMOTE
)

# Substitute values into the script
SCRIPT="${SCRIPT//__DELETE__/$DELETE}"
SCRIPT="${SCRIPT//__MEDIA_DIR__/$MEDIA_DIR}"

if [ "$USE_SSH" = true ]; then
  if [ -n "$SSH_PASS" ]; then
    sshpass -p "$SSH_PASS" ssh $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "bash -s" <<< "$SCRIPT"
  else
    ssh $SSH_OPTS "${SSH_USER}@${SSH_HOST}" "bash -s" <<< "$SCRIPT"
  fi
else
  bash <<< "$SCRIPT"
fi
