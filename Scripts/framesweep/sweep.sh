#!/bin/zsh
# One case: launch a terminal, let FlowPeek settle, and check the frame against the marker bands.
set -e
HERE=${0:a:h}
shape=$1; screen=$2; font=$3; lead=$4
: ${FPTINT:=009E73}
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
snapshot=$($HERE/overlay)
win=$(print "$snapshot" | grep '^window ' | head -1 | cut -d' ' -f2)
out=$(print "$snapshot" | grep '^outline ' | head -1 | cut -d' ' -f2)
outlines=$(print "$snapshot" | grep -c '^outline ')
if [[ -z "$win" ]]; then print "  NO WINDOW"; kill $pid 2>/dev/null; exit 1; fi
IFS=, read wx wy ww wh <<< "$win"
/usr/sbin/screencapture -x -R ${wx%.*},${wy%.*},${ww%.*},${wh%.*} "$HERE/case.png"
bands=$($HERE/bands "$HERE/case.png" 2)
# The chip only appears once the pointer is near the frame, so the second look is taken with it
# there. Moving the pointer is the reader's own gesture and changes nothing else.
if [[ -n "$out" ]]; then
  IFS=, read ox oy ow oh <<< "$out"
  cx=$(( ${ox%.*} + ${ow%.*} / 2 ))
  cy=$(( ${oy%.*} + ${oh%.*} / 2 ))
  [[ -x "$HERE/point" ]] || swiftc -O "$HERE/point.swift" -o "$HERE/point"
  "$HERE/point" $cx $cy >/dev/null 2>&1
  sleep 2
  /usr/sbin/screencapture -x -R ${wx%.*},${wy%.*},${ww%.*},${wh%.*} "$HERE/case-hover.png"
  chip=$($HERE/bands "$HERE/case-hover.png" 2 --tint=$FPTINT | grep '^chip ')
else
  chip="chip none"
fi
kill $pid 2>/dev/null || true
if [[ "$shape" == "two" ]]; then
  # Both blocks have to be framed, and separately.
  if [[ "$outlines" == "2" ]]; then print "  PASS  two blocks, two frames"; else print "  FAIL  two blocks but $outlines frame(s)"; fi
else
  /usr/bin/python3 "$HERE/verdict.py" "$shape" "$win" "${out:-none}" "$bands
$chip"
fi
sleep 1
