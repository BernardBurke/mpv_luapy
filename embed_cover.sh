#!/bin/bash
# embed_cover.sh /path/to/audio_file.m4a
# FIX: Uses -c:v:0 png and -disposition:v:0 attached_pic for robust M4A/MP4 embedding.

AUDIO_FILE="$1"
EXTENSION="${AUDIO_FILE##*.}"
TEMP_FILE="/tmp/temp_audio_file_$(date +%s%N).$EXTENSION"
# NOTE: Ensure you have a placeholder image (e.g., default_cover.png) in your $MPVL directory
DEFAULT_COVER="$MPVL/default_cover.png"

# --- Essential Safety Checks ---
if [[ ! -f "$AUDIO_FILE" ]]; then
    exit 1
fi
if [[ ! -f "$DEFAULT_COVER" ]]; then
    echo "ERROR: Default cover image missing at $DEFAULT_COVER" >&2
    exit 1
fi
if [[ "$EXTENSION" == "wav" ]]; then
    echo "ERROR: Cannot embed cover art in WAV format." >&2
    exit 1
fi

# ----------------------------------------------------------------------
# THE ROBUST FIX: Use PNG codec and attached_pic disposition flag.
# This tells the M4A/MP4 muxer exactly what the stream is for.
# ----------------------------------------------------------------------
if [[ "$EXTENSION" == "m4a" || "$EXTENSION" == "mp4" || "$EXTENSION" == "mov" ]]; then
    
    ffmpeg -i "$AUDIO_FILE" -i "$DEFAULT_COVER" -map 0:a:0 -map 1:v:0 -c:a copy \
        -c:v:0 png \
        -disposition:v:0 attached_pic \
        -metadata:s:v:0 title="Album cover" -metadata:s:v:0 handler="Cover Art" \
        "$TEMP_FILE"
        
else
    # Fallback/default for other formats like MP3/FLAC/OGG (using MJPEG, which is usually fine here)
    ffmpeg -i "$AUDIO_FILE" -i "$DEFAULT_COVER" -map 0:a:0 -map 1:v:0 -c:a copy \
        -c:v:0 mjpeg \
        -disposition:v:0 attached_pic \
        -metadata:s:v:0 title="Album cover" -metadata:s:v:0 handler="Cover Art" \
        "$TEMP_FILE"
fi

if [ $? -eq 0 ]; then
    mv "$TEMP_FILE" "$AUDIO_FILE"
    echo "SUCCESS: Embedded cover art into $AUDIO_FILE"
else
    echo "FFMPEG FAILED with exit code $? . Removing temp file." >&2
    rm -f "$TEMP_FILE"
fi

exit 0