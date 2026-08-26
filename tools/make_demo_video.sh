#!/bin/bash
#
# Builds assets/demo.mp4 from assets/demo.svg and the stems in assets/audio/.
#
#   ./tools/make_demo_video.sh
#
# Three steps, none of them a screen recording: rasterise the SVG frame by frame
# (tools/capture_frames.mjs drives its SMIL clock directly), place each sound
# effect at the timecode of the scene it belongs to, then mux the two together.
# Because the frames and the cues are both addressed by time, the drop lands on
# the frame the file lands on, every run.
#
# Needs ffmpeg, Google Chrome and Node 22+. Takes about twenty minutes on four
# cores; almost all of it is the aurora's blur being re-rasterised 840 times.
#
# The stems were generated once, through Privateer's audio API — the bed with
# Google's Lyria 3, the effects with Stable Audio 3 — and committed, so this
# script needs no API key and no account.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
FPS=${FPS:-30}
DUR=${DUR:-28}
SCALE=${SCALE:-1.5}          # 1.5 × 1280×820 = a 1920×1230 master
WORKERS=${WORKERS:-3}
WORK=${WORK:-$ROOT/.demo-build}
FRAMES=$WORK/frames
mkdir -p "$WORK"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required"; exit 1; }

# ── 1. frames ────────────────────────────────────────────────────────────────
# REUSE=1 keeps the frames from a previous run, which is what you want while
# you're moving a cue by a tenth of a second: the mix and the encode take under
# a minute, the rasterising is the twenty.
TOTAL=$(( FPS * DUR ))
if [ -n "${REUSE:-}" ] && [ "$(ls "$FRAMES" 2>/dev/null | wc -l | tr -d ' ')" = "$TOTAL" ]; then
  echo "Reusing $TOTAL frames in $FRAMES"
else
rm -rf "$FRAMES"; mkdir -p "$FRAMES"
SLICE=$(( (TOTAL + WORKERS - 1) / WORKERS ))
echo "Rasterising $TOTAL frames across $WORKERS workers…"
for ((w = 0; w < WORKERS; w++)); do
  START=$(( w * SLICE ))
  END=$(( START + SLICE )); (( END > TOTAL )) && END=$TOTAL
  (( START >= END )) && continue
  OUT="$FRAMES" SCALE="$SCALE" FPS="$FPS" DUR="$DUR" PORT=$(( 9411 + w )) \
    START="$START" END="$END" node tools/capture_frames.mjs > "$WORK/worker-$w.log" 2>&1 &
done
wait
echo "  $(ls "$FRAMES" | wc -l | tr -d ' ') frames"
fi

# ── 2. sound ─────────────────────────────────────────────────────────────────
# name  start(s)  length(s)  gain(dB) — the gain lands each effect a fixed
# distance under the bed, which is mixed well down so the app can be heard.
CUES=(
  "chime  0.30  3.00  21"    # the lantern, on the title card
  "whoosh 2.25  2.00   3"    # the window arrives
  "type   3.50  6.35  16"    # the note being written
  "chime 10.40  3.00  22"    # ⌘P renders it
  "click 14.95  1.00  10"    # ⌘F opens the find bar
  "whoosh 18.95 2.00   3"    # the file, on its way in
  "drop  20.00  2.00   0"    # it lands
  "swell 22.45  4.00   5"    # ⌘0, and everything else leaves
  "chime 25.95  3.00  21"    # back to the lantern, where the loop began
)

FMT="aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo"
INPUTS=(-i assets/audio/bed.mp3)
FILTER="[0:a]atrim=0:$DUR,asetpts=PTS-STARTPTS,$FMT,dynaudnorm=f=300:g=11:p=0.62:m=6:s=8,volume=-12dB,"
FILTER+="afade=t=in:st=0:d=1.6,afade=t=out:st=$(echo "$DUR - 1.8" | bc):d=1.8[bed];"
MIX="[bed]"; n=1
for cue in "${CUES[@]}"; do
  read -r name start len gain <<< "$cue"
  INPUTS+=(-i "assets/audio/$name.mp3")
  ms=$(awk -v s="$start" 'BEGIN{printf "%d", s * 1000}')
  fade=$(awk -v t="$len" 'BEGIN{printf "%.2f", (t > 0.6 ? t - 0.35 : t * 0.6)}')
  FILTER+="[$n:a]atrim=0:$len,asetpts=PTS-STARTPTS,$FMT,volume=${gain}dB,"
  FILTER+="afade=t=out:st=${fade}:d=0.35,adelay=${ms}|${ms}[s$n];"
  MIX+="[s$n]"; n=$(( n + 1 ))
done
FILTER+="${MIX}amix=inputs=$n:normalize=0:dropout_transition=0,volume=7dB,"
FILTER+="alimiter=level_in=1:limit=0.71:attack=4:release=90:level=disabled,atrim=0:$DUR,aresample=48000[out]"

echo "Mixing $n stems…"
ffmpeg -y -hide_banner -loglevel error "${INPUTS[@]}" -filter_complex "$FILTER" \
  -map "[out]" -c:a aac -b:a 192k -ar 48000 "$WORK/mix.m4a"

# ── 3. the film ──────────────────────────────────────────────────────────────
echo "Encoding…"
ffmpeg -y -hide_banner -loglevel error -framerate "$FPS" -i "$FRAMES/%05d.png" \
  -i "$WORK/mix.m4a" -c:v libx264 -preset slow -crf 20 -pix_fmt yuv420p \
  -c:a aac -b:a 192k -movflags +faststart -shortest assets/demo.mp4

echo "assets/demo.mp4 — $(du -h assets/demo.mp4 | cut -f1), ${DUR}s"
