#!/bin/bash
set -uo pipefail

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
RESOLUTION="${RESOLUTION:-300}"
MODE="${MODE:-Color}"
SOURCE="${SOURCE:-ADF Duplex}"
POLL_INTERVAL="${POLL_INTERVAL:-0.5}"
DEBOUNCE="${DEBOUNCE:-3}"
# Optional Healthchecks-style ping URL (no trailing slash). Pinged hourly while
# the scanner answers, and at /fail when a scan fails.
HC_URL="${HC_URL:-}"
HC_EVERY="${HC_EVERY:-3600}"
# Seconds the scanner may stop answering before the loop exits, so the
# container restarts and finds the device again.
LOST_AFTER="${LOST_AFTER:-60}"
# Touched each time the scanner answers; the Docker healthcheck reads its age.
ALIVE_FILE=/tmp/scanner-ok

hc() {
    [ -n "$HC_URL" ] || return 0
    curl -fsS -m 10 --retry 3 -o /dev/null --data-raw "${2:-}" "$HC_URL$1" || echo "heartbeat ping failed"
}

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
LAST_OK=$(date +%s)
LAST_PING=0
while true; do
    NOW=$(date +%s)
    OPTIONS=$(scanimage -d "$DEVICE" -A 2>/dev/null || true)
    if [ -n "$OPTIONS" ]; then
        LAST_OK=$NOW
        touch "$ALIVE_FILE"
        if [ $((NOW - LAST_PING)) -ge "$HC_EVERY" ]; then
            hc "" "scanner attached: $DEVICE"
            LAST_PING=$NOW
        fi
    elif [ $((NOW - LAST_OK)) -ge "$LOST_AFTER" ]; then
        echo "Scanner not answering for ${LOST_AFTER}s, exiting so the container restarts"
        hc "/fail" "scanner not answering for ${LOST_AFTER}s: $DEVICE"
        exit 1
    fi
    BUTTON=$(echo "$OPTIONS" | grep -- '--scan' | grep -oP '\[\K(yes|no)(?=\])' || true)

    if [ "$BUTTON" = "yes" ]; then
        TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
        WORKDIR=$(mktemp -d)
        echo "[$TIMESTAMP] Scan button pressed — scanning..."

        # Scan all pages from ADF
        SCAN_OUTPUT=$(timeout 120 scanimage -d "$DEVICE" \
            --source "$SOURCE" \
            --resolution "$RESOLUTION" \
            --mode "$MODE" \
            --page-width 221 \
            --page-height 876 \
            --ald=yes \
            --swdeskew=yes \
            --swdespeck 2 \
            --format=tiff \
            --batch="$WORKDIR/page-%04d.tiff" \
            --batch-count=-1 2>&1)
        SCAN_EXIT=$?

        echo "$SCAN_OUTPUT"

        # Check scanner sensors for error state
        SENSORS=$(scanimage -d "$DEVICE" -A 2>/dev/null | grep -E '\[hardware\]' || true)
        if echo "$SENSORS" | grep -q 'cover-open.*\[yes\]'; then
            echo "[$TIMESTAMP] SENSOR: Cover open detected"
        fi
        if echo "$SENSORS" | grep -q 'omr-df.*\[yes\]'; then
            echo "[$TIMESTAMP] SENSOR: Double feed detected"
        fi
        if echo "$SENSORS" | grep -q 'double-feed.*\[yes\]'; then
            echo "[$TIMESTAMP] SENSOR: Double feed confirmed"
        fi
        ERROR_CODE=$(echo "$SENSORS" | grep 'error-code' | grep -oP '\[\K\d+(?=\])' || echo "0")
        if [ "$ERROR_CODE" != "0" ]; then
            echo "[$TIMESTAMP] SENSOR: Error code $ERROR_CODE"
        fi
        if [ "$SCAN_EXIT" -eq 124 ]; then
            echo "[$TIMESTAMP] TIMEOUT: scanimage killed after 120s (feeder hang?)"
            hc "/fail" "scan timed out after 120s (feeder hang?)"
        elif [ "$SCAN_EXIT" -ne 0 ]; then
            echo "[$TIMESTAMP] scanimage exited with code $SCAN_EXIT"
        fi

        # Count pages
        PAGE_COUNT=$(ls "$WORKDIR"/page-*.tiff 2>/dev/null | wc -l)

        if [ "$PAGE_COUNT" -gt 0 ]; then
            OUTFILE="$OUTPUT_DIR/scan-$TIMESTAMP.pdf"
            # Post-process each page
            for f in "$WORKDIR"/page-*.tiff; do
                # Trim scanner background, white balance, normalize, sharpen
                convert "$f" -bordercolor "#c0d0c0" -fuzz 8% -trim +repage \
                    -white-threshold 88% -normalize -sharpen 0x1 "$f"
            done

            if convert "$WORKDIR"/page-*.tiff "$OUTFILE"; then
                echo "[$TIMESTAMP] Saved $PAGE_COUNT pages to $OUTFILE"
            else
                echo "[$TIMESTAMP] ERROR: Failed to create PDF"
                hc "/fail" "failed to create PDF for $PAGE_COUNT pages"
            fi
        else
            echo "[$TIMESTAMP] No pages scanned (empty ADF?)"
        fi

        rm -rf "$WORKDIR"
        # The scan held up polling; the scanner was answering throughout.
        LAST_OK=$(date +%s)
        touch "$ALIVE_FILE"

        # Debounce — ignore button for a few seconds
        sleep "$DEBOUNCE"
    fi

    sleep "$POLL_INTERVAL"
done
