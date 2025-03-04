#!/bin/bash

# Ensure correct arguments
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <top-level-directory> <YYYY-MM-DD>"
    exit 1
fi

TOP_DIR="$1"
DATE="$2"
SERATO_DIR="$HOME/Music/_Serato_"
SERATO_DB="$SERATO_DIR/Database V2"
OVERVIEW_BUILDER="$SERATO_DIR/OverviewBuilder"
CRATES_DIR="$SERATO_DIR/Subcrates"
ARCHIVE_DIR="$HOME/Library/CloudStorage/audio/archived-lowres-audio"
TODAY=$(date +"%y%m%d")  # Format for today's date (YYMMDD)
CRATE_NAME="new-$TODAY"
CRATE_FILE="$CRATES_DIR/$CRATE_NAME.crate"
LOG_FILE="$HOME/serato_import_log_$TODAY.txt"
ARCHIVE_LOG="$HOME/serato_archive_cleanup_log.txt"

# Configuration Flags
DELETE_OLD_ARCHIVED_FILES=true  # Set to false to prevent deletion
DRY_RUN=true  # Set to true for a test run (no actual changes)

# Ensure Serato database exists
if [ ! -f "$SERATO_DB" ]; then
    echo "Error: Serato database not found at $SERATO_DB."
    exit 1
fi

# Create necessary directories
mkdir -p "$CRATES_DIR"
mkdir -p "$OVERVIEW_BUILDER"
mkdir -p "$ARCHIVE_DIR"

# Convert date to days ago for find command
DAYS_AGO=$(( ($(date +%s) - $(date -d "$DATE" +%s)) / 86400 ))

# Validate date format
if ! date -d "$DATE" >/dev/null 2>&1; then
    echo "Error: Invalid date format. Use YYYY-MM-DD."
    exit 1
fi

echo "Searching for .m4a files in $TOP_DIR created on or after $DATE..."
FOUND_FILES=$(find "$TOP_DIR" -type f -iname "*.m4a" -ctime -"$DAYS_AGO")

# Check if files were found
if [ -z "$FOUND_FILES" ]; then
    echo "No new .m4a files found."
    exit 0
fi

echo "Dry-Run Mode: $DRY_RUN"
echo "Adding files to Serato database and playlist: $CRATE_NAME"
echo "Processing log saved at $LOG_FILE"

# Backup Serato Database and OverviewBuilder if not in dry-run mode
if [ "$DRY_RUN" = false ]; then
    cp "$SERATO_DB" "$SERATO_DB.bak"
    cp -r "$OVERVIEW_BUILDER" "$OVERVIEW_BUILDER.bak"
fi

# Create a new crate file
if [ "$DRY_RUN" = false ]; then
    echo "Crate: $CRATE_NAME" > "$CRATE_FILE"
fi

# Process each file
while IFS= read -r FILE; do
    FILE_BASENAME=$(basename "$FILE")

    # Check if file already exists in Serato
    EXISTING_FILE=$(grep "$FILE_BASENAME" "$SERATO_DB" | awk -F'"' '{print $2}')
    if [ -n "$EXISTING_FILE" ]; then
        echo "Existing file found: $EXISTING_FILE"

        # Get existing & new file bitrates
        EXISTING_BITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "$EXISTING_FILE")
        NEW_BITRATE=$(ffprobe -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "$FILE")

        if [[ "$NEW_BITRATE" -gt "$EXISTING_BITRATE" ]]; then
            echo "Replacing with higher bitrate: $NEW_BITRATE kbps > $EXISTING_BITRATE kbps"

            # Archive the old file instead of deleting it
            ARCHIVE_PATH="$ARCHIVE_DIR/$(basename "$EXISTING_FILE")"
            if [ "$DRY_RUN" = false ]; then
                echo "Archiving old file: $EXISTING_FILE → $ARCHIVE_PATH"
                mv "$EXISTING_FILE" "$ARCHIVE_PATH"
            else
                echo "[Dry-Run] Would archive: $EXISTING_FILE → $ARCHIVE_PATH"
            fi
        elif [[ "$NEW_BITRATE" -eq "$EXISTING_BITRATE" ]]; then
            echo "Bitrate is the same. Keeping existing file but tagging metadata."
            if [ "$DRY_RUN" = false ]; then
                exiftool -overwrite_original -Comment+=" serato-cues" "$EXISTING_FILE"
                exiftool -overwrite_original -Comment+=" rekordbox-cues" "$EXISTING_FILE"
            else
                echo "[Dry-Run] Would tag metadata: $EXISTING_FILE (serato-cues, rekordbox-cues)"
            fi
            continue
        else
            echo "Skipping (existing file is same or higher quality)."
            continue
        fi
    fi

    echo "Adding: $FILE_BASENAME"

    # Append to Serato Database
    if [ "$DRY_RUN" = false ]; then
        echo "Song File Path=\"$FILE\"" >> "$SERATO_DB"
        echo "$FILE" >> "$CRATE_FILE"
        touch "$OVERVIEW_BUILDER/$FILE_BASENAME.analyze"
    else
        echo "[Dry-Run] Would add: $FILE_BASENAME to Serato database and crate."
    fi

    # Log processed file
    echo "$FILE ($NEW_BITRATE kbps) - Tags: serato-cues rekordbox-cues" >> "$LOG_FILE"

done <<< "$FOUND_FILES"

# Delete archived files older than 30 days if override is not set
if [ "$DELETE_OLD_ARCHIVED_FILES" = true ]; then
    if [ "$DRY_RUN" = false ]; then
        echo "Removing archived files older than 30 days..."
        find "$ARCHIVE_DIR" -type f -mtime +30 -exec rm {} \; -exec echo "Deleted: {}" >> "$ARCHIVE_LOG" \;
    else
        echo "[Dry-Run] Would remove archived files older than 30 days."
    fi
else
    echo "Manual override enabled. Old archived files will not be deleted."
fi

echo "Files added. Restarting Serato and forcing analysis..."

# Relaunch Serato DJ Pro if not in dry-run mode
if [ "$DRY_RUN" = false ]; then
    osascript -e 'quit app "Serato DJ Pro"' >/dev/null 2>&1
    sleep 2
    open -a "Serato DJ Pro"
    echo "Done! The new files should now be in Serato under the crate: $CRATE_NAME and queued for waveform analysis."
else
    echo "[Dry-Run] Would restart Serato DJ Pro."
fi

