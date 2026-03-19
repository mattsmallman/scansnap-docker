#!/bin/bash
set -euo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
RESOLUTION="${RESOLUTION:-300}"
MODE="${MODE:-Color}"
SOURCE="${SOURCE:-ADF Duplex}"
POLL_INTERVAL="${POLL_INTERVAL:-0.5}"
DEBOUNCE="${DEBOUNCE:-3}"

echo "ScanSnap button scanner starting..."
echo "Output: $OUTPUT_DIR | Resolution: $RESOLUTION | Mode: $MODE | Source: $SOURCE"

# Wait for scanner to appear
while true; do
    DEVICE=$(scanimage -L 2>/dev/null | grep -oP "fujitsu:[^'\`]+" || true)
    if [ -n "$DEVICE" ]; then
        echo "Found scanner: $DEVICE"
        break
    fi
    echo "Waiting for scanner..."
    sleep 5
done

# Poll for button press
while true; do
    BUTTON=$(scanimage -d "$DEVICE" -A 2>/dev/null | grep -- '--scan' | grep -oP '\[\K(yes|no)(?=\])' || true)

    if [ "$BUTTON" = "yes" ]; then
        TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
        WORKDIR=$(mktemp -d)
        echo "[$TIMESTAMP] Scan button pressed — scanning..."

        # Scan all pages from ADF
        scanimage -d "$DEVICE" \
            --source "$SOURCE" \
            --resolution "$RESOLUTION" \
            --mode "$MODE" \
            --format=tiff \
            --batch="$WORKDIR/page-%04d.tiff" \
            --batch-count=-1 2>&1 || true

        # Count pages
        PAGE_COUNT=$(ls "$WORKDIR"/page-*.tiff 2>/dev/null | wc -l)

        if [ "$PAGE_COUNT" -gt 0 ]; then
            OUTFILE="$OUTPUT_DIR/scan-$TIMESTAMP.pdf"
            magick "$WORKDIR"/page-*.tiff "$OUTFILE"
            echo "[$TIMESTAMP] Saved $PAGE_COUNT pages to $OUTFILE"
        else
            echo "[$TIMESTAMP] No pages scanned (empty ADF?)"
        fi

        rm -rf "$WORKDIR"

        # Debounce — ignore button for a few seconds
        sleep "$DEBOUNCE"
    fi

    sleep "$POLL_INTERVAL"
done
