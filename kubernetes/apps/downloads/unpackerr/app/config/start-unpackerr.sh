#!/bin/sh
set -eu

if [ ! -s /config/unpackerr.conf ]; then
  cp /seed/unpackerr.conf /config/unpackerr.conf
  echo "Seeded /config/unpackerr.conf from config"
fi

ln -sfn /history/unpackerr.history.jsonl /config/unpackerr.history.jsonl
echo "History: /history/unpackerr.history.jsonl"

exec /unpackerr "$@"
