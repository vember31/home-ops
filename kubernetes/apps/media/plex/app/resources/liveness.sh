#!/bin/sh

PORT="$1"
HTTP_ENDPOINT="$2"
shift 2

if [ -z "$PORT" ] || [ "$#" -eq 0 ]; then
    echo "Usage: $0 <port> <http_endpoint> <directory1> [directory2 ...]"
    exit 1
fi

if ! curl -fs --max-time 3 "http://localhost:${PORT}/${HTTP_ENDPOINT}" > /dev/null; then
    echo "Plex health check failed (http://localhost:${PORT}/${HTTP_ENDPOINT})"
    exit 1
fi

for dir; do
    if ! ls "$dir" > /dev/null 2>&1; then
        echo "Stale NFS handle: $dir"
        exit 1
    fi
done

exit 0