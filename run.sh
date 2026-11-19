#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$HOME/Downloads/($(date +%-y-%-m-%-d)) Youtube DL LINKS.txt"
# The analyzer's stderr (refusals, warnings) goes to the file the app uses for it
# (ORION_LOG_DIR overrides the folder, as in app_run.py).
ANALYZER_LOG="${ORION_LOG_DIR:-$HOME/Library/Logs/Beat Key}/analyzer.log"
mkdir -p "$(dirname "$ANALYZER_LOG")"

source "$SCRIPT_DIR/deps.sh"
ensure_deps || exit 1
maybe_upgrade_ytdlp

log_download() {
    printf "Input URL: %s\n" "$url" >> "$LOG_FILE"
    printf "Downloaded: %s\n\n" "$1" >> "$LOG_FILE"
}

# Detect BPM + key into $bpm $key1 $key2 $key3 (empty bpm = analysis failed)
analyze() {
    echo "Analyzing..."
    local analysis errs rc=0
    errs=$(mktemp)
    analysis=$("$PY" "$SCRIPT_DIR/bpm.py" "$1" 2>"$errs") || rc=$?
    if [ -s "$errs" ]; then
        { printf "%s run.sh: bpm.py exit %s on %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$rc" "$(basename "$1")"
          cat "$errs"; } >> "$ANALYZER_LOG"
        echo "The analyzer reported a problem; details in $ANALYZER_LOG"
    fi
    rm -f "$errs"
    [ "$rc" -eq 0 ] || analysis=""
    bpm=$(echo "$analysis" | sed -n '1p')
    key1=$(echo "$analysis" | sed -n '2p')
    key2=$(echo "$analysis" | sed -n '3p')
    key3=$(echo "$analysis" | sed -n '4p')
}

# A dropped beat: show BPM + key, leave the file as it is
analyze_beat() {
    echo ""
    echo "$(basename "$1")"
    analyze "$1"
    if [ -n "$bpm" ]; then
        echo "BPM: $bpm"
        echo "Key: $key1 | $key2 | $key3"
    else
        echo "Couldn't analyze that file."
    fi
}

while true; do
    printf "\nURL/Beat: "
    read -r url

    [ -z "$url" ] && break

    if [[ "$url" != http://* && "$url" != https://* ]]; then
        beats=$("$PY" "$SCRIPT_DIR/dropped.py" "$url")
        case $? in
            0) while IFS= read -r beat; do
                   analyze_beat "$beat"
               done <<< "$beats"
               continue ;;
            1) continue ;;
        esac
    fi

    echo "Downloading..."

    filepath=$("$PY" "$SCRIPT_DIR/downloader.py" "$url")

    # downloader.py is the one retry layer (it walks its strategies); yt-dlp itself is
    # upgraded weekly at start-up (maybe_upgrade_ytdlp), not after a failure.
    if [ $? -ne 0 ] || [ -z "$filepath" ]; then
        continue
    fi

    analyze "$filepath"

    if [ -n "$bpm" ]; then
        k1=$(echo "$key1" | sed 's/ (.*//')
        k2=$(echo "$key2" | sed 's/ (.*//')
        k3=$(echo "$key3" | sed 's/ (.*//')
        dir=$(dirname "$filepath")
        base=$(basename "$filepath")
        ext="${base##*.}"
        stem="${base%.*}"
        newpath="$dir/$stem (${bpm} BPM $k1 $k2 $k3).$ext"
        mv "$filepath" "$newpath"
        downloaded_name="$(basename "$newpath")"
        echo "Downloaded: $downloaded_name"
        echo "Key: $key1 | $key2 | $key3"
        log_download "$downloaded_name"
    else
        downloaded_name="$(basename "$filepath")"
        echo "Downloaded: $downloaded_name"
        log_download "$downloaded_name"
    fi

done
