#!/bin/bash

# This script will take a first directory of original files, and compare them to a second directory
# of files that contains hardlinks. The hardlinks will be turned into unique files.

# Optionally takes a parameter --report.

# Ex usage: ./match_hardlinks.sh --report /path/to/originals /path/to/hardlinks

# Check if the required directories are provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 [--report] <originals_directory> <potential_hardlinks_directory>"
    exit 1
fi

# Custom temporary directory for breaking hardlinks
TEMP_DIR="/export/tv/tmp"

# Ensure the temporary directory exists
if [ ! -d "$TEMP_DIR" ]; then
    echo "Temporary directory $TEMP_DIR does not exist. Please create it."
    exit 1
fi

# Check for report mode flag
REPORT_MODE=false
if [ "$1" == "--report" ]; then
    REPORT_MODE=true
    shift  # Remove the --report flag from the argument list
fi

ORIGINALS_DIR=$1
HARDLINKS_DIR=$2

declare -A original_files

# Find all files in the originals directory and store their inodes
while IFS= read -r -d '' file; do
    inode=$(stat --format='%i' "$file")
    original_files["$inode"]="$file"
done < <(find "$ORIGINALS_DIR" -type f -print0)

# Now check the potential hardlinks directory
find "$HARDLINKS_DIR" -type f -exec stat --format='%i %n' {} + | sort -n | \
    while read -r inode filepath; do
        if [[ -n "${original_files[$inode]}" ]]; then
            echo "Hardlink: $filepath"
            echo "Original: ${original_files[$inode]}"
            if [ "$REPORT_MODE" == true ]; then
                echo "[REPORT] Would break the hardlink and convert $filepath to a physical file."
            else
                # Break the hardlink by copying to a temporary file in the custom temp directory, then moving it back
                temp_file="$TEMP_DIR/$(basename "$filepath")_temp"
                cp "$filepath" "$temp_file"     # Copy the file to a temporary file
                rm "$filepath"                  # Remove the original hardlinked file
                mv "$temp_file" "$filepath"     # Move the temporary file back to its original location
                echo "Hardlink converted to a physical file: $filepath"
            fi
        fi
    done

if [ "$REPORT_MODE" == true ]; then
    echo "Report mode: No changes were made."
else
    echo "Hardlinks in $HARDLINKS_DIR have been converted to physical files."
fi
