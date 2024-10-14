#!/bin/sh

# Variables passed as arguments
PORT="$1"
HTTP_ENDPOINT="$2"
shift 2  # Shift arguments to process the remaining as directories
DIRECTORIES="$@"

# Check if at least the port and one directory are provided
if [ -z "$PORT" ] || [ -z "$DIRECTORIES" ]; then
    echo "Usage: $0 <port> [http_endpoint] <directory1> [directory2 ... directoryN]"
    exit 1
fi

# If no HTTP endpoint is provided, perform a standard liveness check on the port
if [ -z "$HTTP_ENDPOINT" ]; then
    if ! curl -f -s "http://localhost:$PORT" > /dev/null; then
        echo "Standard liveness check failed on port $PORT."
        exit 1
    fi
else
    # If an HTTP endpoint is provided, perform an HTTP GET request to it instead
    if ! curl -f -s "$HTTP_ENDPOINT" > /dev/null; then
        echo "HTTP GET request failed for endpoint $HTTP_ENDPOINT."
        exit 1
    fi
fi

# Loop through all directories and check for stale file handles
for DIRECTORY in $DIRECTORIES; do
    if ! ls "$DIRECTORY" > /dev/null 2>&1; then
        echo "Stale file handle detected in directory $DIRECTORY."
        exit 1
    fi
done

echo "All checks passed."
exit 0