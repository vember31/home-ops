#!/bin/sh
set -eu

if [ ! -s /config/unpackerr.conf ]; then
  cp /seed/unpackerr.conf /config/unpackerr.conf
  echo "Seeded /config/unpackerr.conf from config"
fi

exec /unpackerr "$@"
