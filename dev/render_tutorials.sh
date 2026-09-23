#!/usr/bin/env bash
# ============================================================================
# MIDI-GPT for REAPER -- render tutorial videos (NOT for end users)
#
# Burns each video's captions (docs/tutorials/captions/<ID>.srt) into its
# raw screen recording (tutorials-raw/<ID>.mov or .mp4) and adds a short
# title card, writing tutorials-out/<ID>.mp4 -- ready to upload.
#
# The title card text comes from the first line of
# docs/tutorials/shotlists/<ID>.md ("# <ID> · <Title>").
#
# Captions are shifted by the title card's length, so write .srt timings
# against the raw recording. Re-running after a caption fix only takes a
# re-encode -- no re-recording.
#
# Usage:
#   ./dev/render_tutorials.sh            # every recording in tutorials-raw/
#   ./dev/render_tutorials.sh B3 A2      # just these IDs
#
# Needs ffmpeg built with libass (subtitles filter) and freetype (drawtext)
# -- see the check below for where to get one.
# ============================================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RAW_DIR="$REPO_DIR/tutorials-raw"
OUT_DIR="$REPO_DIR/tutorials-out"
CAPTIONS_DIR="$REPO_DIR/docs/tutorials/captions"
SHOTLISTS_DIR="$REPO_DIR/docs/tutorials/shotlists"

TITLE_SECONDS=2
FONT="${TUTORIAL_FONT:-Helvetica}"
CAPTION_STYLE="FontName=$FONT,FontSize=20,PrimaryColour=&H00FFFFFF,BorderStyle=3,Outline=6,BackColour=&H99000000,Shadow=0,MarginV=36"

# FFMPEG/FFPROBE override which binaries are used (e.g. a static build).
FFMPEG="${FFMPEG:-ffmpeg}"
FFPROBE="${FFPROBE:-ffprobe}"
command -v "$FFMPEG" >/dev/null || { echo "ffmpeg not found"; exit 1; }
# Homebrew's core ffmpeg no longer includes libass/freetype. Builds that do:
# the homebrew-ffmpeg tap, or the static builds from https://evermeet.cx/ffmpeg/
# (then run with FFMPEG=/path/to/ffmpeg FFPROBE=/path/to/ffprobe).
for filter in subtitles drawtext; do
    if ! "$FFMPEG" -hide_banner -filters 2>/dev/null | grep -q " $filter "; then
        echo "This ffmpeg has no '$filter' filter (it needs libass and freetype)."
        echo "Install one that does, e.g.:"
        echo "  brew tap homebrew-ffmpeg/ffmpeg && brew install homebrew-ffmpeg/ffmpeg/ffmpeg"
        echo "or download a static build from https://evermeet.cx/ffmpeg/ and set FFMPEG/FFPROBE."
        exit 1
    fi
done
mkdir -p "$OUT_DIR"

if [ $# -gt 0 ]; then
    IDS=("$@")
else
    IDS=()
    for f in "$RAW_DIR"/*.mov "$RAW_DIR"/*.mp4; do
        [ -e "$f" ] && IDS+=("$(basename "${f%.*}")")
    done
    [ ${#IDS[@]} -gt 0 ] || { echo "No recordings in $RAW_DIR"; exit 1; }
fi

# ffmpeg filter arguments need ' : \ escaped.
escape_filter() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g" -e 's/:/\\:/g'; }

for id in "${IDS[@]}"; do
    raw=""
    for ext in mov mp4; do
        [ -f "$RAW_DIR/$id.$ext" ] && raw="$RAW_DIR/$id.$ext" && break
    done
    srt="$CAPTIONS_DIR/$id.srt"
    shotlist="$SHOTLISTS_DIR/$id.md"
    [ -n "$raw" ] || { echo "[$id] no recording in $RAW_DIR -- skipped"; continue; }
    [ -f "$srt" ] || { echo "[$id] no captions at $srt -- skipped"; continue; }

    title="$id"
    [ -f "$shotlist" ] && title="$(head -1 "$shotlist" | sed -e 's/^# *//')"

    # Shift the captions by the title card's length.
    shifted="$(mktemp -t "$id").srt"
    "$FFMPEG" -loglevel error -y -itsoffset "$TITLE_SECONDS" -i "$srt" "$shifted"

    size="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$raw")"
    fps="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 "$raw")"

    echo "[$id] $title ($size @ $fps)"
    # Title card (dark background, series title + video title), then the
    # recording with burned-in captions. Recordings are silent, so a silent
    # audio track is added for players/uploads that expect one.
    "$FFMPEG" -loglevel error -stats -y \
        -f lavfi -i "color=c=0x16161a:s=$size:r=$fps:d=$TITLE_SECONDS" \
        -i "$raw" \
        -f lavfi -i "anullsrc=r=48000:cl=stereo" \
        -filter_complex "\
[0:v]drawtext=font='$(escape_filter "$FONT")':text='MIDI-GPT for REAPER':fontcolor=0xbbbbbb:fontsize=h/22:x=(w-tw)/2:y=h/2-th*2,\
drawtext=font='$(escape_filter "$FONT")':text='$(escape_filter "$title")':fontcolor=white:fontsize=h/14:x=(w-tw)/2:y=h/2,format=yuv420p[title];\
[1:v]fps=$fps,format=yuv420p,setsar=1[rec];\
[title][rec]concat=n=2:v=1:a=0[joined];\
[joined]subtitles='$(escape_filter "$shifted")':force_style='$CAPTION_STYLE'[v]" \
        -map "[v]" -map 2:a -shortest \
        -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p -c:a aac -b:a 64k \
        -movflags +faststart \
        "$OUT_DIR/$id.mp4"
    rm -f "$shifted"
done

echo "Done -- videos in $OUT_DIR"
