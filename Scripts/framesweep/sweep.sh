#!/bin/zsh
# One case: launch a terminal, let FlowPeek settle, and check the frame against the marker bands.
set -e
HERE=${0:a:h}
shape=$1; screen=$2; font=$3; lead=$4
# Build the two measuring tools the first time, next to the scripts.
[[ -x "$HERE/bands" ]] || swiftc -O "$HERE/bands.swift" -o "$HERE/bands"
[[ -x "$HERE/overlay" ]] || swiftc -O "$HERE/overlay.swift" -o "$HERE/overlay"
/usr/bin/open -na /Applications/Ghostty.app --args --font-size=$font --title=FPSWEEP \
  --command="/usr/bin/python3 $HERE/sweepprint.py $shape $screen $lead"
sleep 5
pid=$(pgrep -x ghostty | grep -v '^1510$' | head -1)
[[ -z "$pid" ]] && { print "  LAUNCH FAILED"; exit 1 }
# Grow the window so a large font still leaves both markers on screen, and let the printer
# repaint at the new size.
/usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set size of window 1 to {1180, 880}" >/dev/null 2>&1
sleep 2
/usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set frontmost to true" >/dev/null 2>&1
sleep 6
win=$($HERE/overlay | grep '^window ' | head -1 | cut -d' ' -f2)
out=$($HERE/overlay | grep '^outline ' | head -1 | cut -d' ' -f2)
if [[ -z "$win" ]]; then print "  NO WINDOW"; kill $pid 2>/dev/null; exit 1; fi
IFS=, read wx wy ww wh <<< "$win"
/usr/sbin/screencapture -x -R ${wx%.*},${wy%.*},${ww%.*},${wh%.*} "$HERE/case.png"
bands=$($HERE/bands "$HERE/case.png" 2)
kill $pid 2>/dev/null || true
/usr/bin/python3 "$HERE/verdict.py" "$shape" "$win" "${out:-none}" "$bands"
sleep 1
