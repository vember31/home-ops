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

# Function to check HTTP response output
check_http_output() {
    OUTPUT=$(curl -f -s "http://localhost:$PORT$HTTP_ENDPOINT")
    if [ -z "$OUTPUT" ]; then
        echo "HTTP request to http://localhost:$PORT$HTTP_ENDPOINT returned no output."
        exit 1
    fi
}

# If no HTTP endpoint is provided, perform a standard liveness check on the port
if [ -z "$HTTP_ENDPOINT" ]; then
    check_http_output
else
    # If an HTTP endpoint is provided, perform an HTTP GET request to it instead
    check_http_output
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
