#!/bin/bash
# embed_cover.sh /path/to/audio_file.m4a
# Dependencies: ffmpeg, a placeholder image at $HOME/default_cover.jpg

AUDIO_FILE="$1"
TEMP_FILE="/tmp/temp_audio_file_$(date +%s%N).m4a"
DEFAULT_COVER="$HOME/default_cover.jpg"

if [[ ! -f "$AUDIO_FILE" ]]; then
    exit 1
fi

# Ensure the placeholder exists (you must create this manually)
if [[ ! -f "$DEFAULT_COVER" ]]; then
    # Fallback/error message if cover is missing
    echo "ERROR: Default cover image missing at $DEFAULT_COVER" >&2
    exit 1
fi

# Check file extension and set output format
EXTENSION="${AUDIO_FILE##*.}"

if [[ "$EXTENSION" == "wav" ]]; then
    # Reject .wav as it doesn't support metadata/tags easily for embedding
    echo "ERROR: Cannot embed cover art in WAV format." >&2
    exit 1
fi

# Use FFmpeg to copy the audio stream (-c:a copy) and map the image as a cover art stream (-map 0 -map 1)
# Note: Output format is hardcoded to M4A/MP4 tags, which works for MP3/M4A/FLAC/OGG containers.
ffmpeg -i "$AUDIO_FILE" -i "$DEFAULT_COVER" -map 0:a:0 -map 1:v:0 -c copy \
    -metadata:s:v:0 title="Album cover" -metadata:s:v:0 handler="Cover Art" \
    "$TEMP_FILE"

if [ $? -eq 0 ]; then
    # Replace original file with the new file
    mv "$TEMP_FILE" "$AUDIO_FILE"
    echo "SUCCESS: Embedded cover art into $AUDIO_FILE"
else
    echo "FFMPEG FAILED" >&2
    rm -f "$TEMP_FILE"
fi