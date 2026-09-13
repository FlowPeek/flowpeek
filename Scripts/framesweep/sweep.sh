#!/bin/zsh
# One case: launch a terminal, let FlowPeek settle, and check the frame against the marker bands.
set -e
HERE=${0:a:h}
shape=$1; screen=$2; font=$3; lead=$4
# The hint tint, taken from the build under test rather than assumed.
#
# It was hard-coded to the default green, and the default is not what anyone is running: the first
# sweep against a real installation reported the chip missing on every case, because that app is set
# to #CC79A7 and the finder was hunting for #009E73. The frame was exactly where it should be in all
# of them. A tint is the reader's choice, so it is an input to the test, not a thing under test --
# the geometry below is still measured off the screen and nothing FlowPeek computes is used.
: ${FPDOMAIN:=$(pgrep -f "FlowPeek Debug.app" >/dev/null && print com.selenehyun.FlowPeek.debug || print com.selenehyun.FlowPeek)}
: ${FPTINT:=$(defaults read $FPDOMAIN flowpeek.hint.tint 2>/dev/null | tr -d '#[:space:]')}
: ${FPTINT:=009E73}
: ${FPUSER:=1510}
# Build the two measuring tools the first time, next to the scripts.
for tool in bands overlay point scrollto; do
  [[ -x "$HERE/$tool" ]] || swiftc -O "$HERE/$tool.swift" -o "$HERE/$tool"
done
/usr/bin/open -na /Applications/Ghostty.app --args --font-size=$font --title=FPSWEEP \
  --command="/usr/bin/python3 $HERE/sweepprint.py $shape $screen $lead"
# Wait for the window rather than for a fixed time. Run back to back, the previous terminal is
# still closing when the next is asked for, and a stale pid put two of twenty-four cases into a
# failure that reproduced nowhere on its own.
pid=""
for attempt in $(seq 1 20); do
  sleep 1
  if [[ -n "$($HERE/overlay 2>/dev/null | grep '^window ')" ]]; then
    for candidate in $(pgrep -x ghostty); do
      [[ "$candidate" == "$FPUSER" ]] && continue
      pid=$candidate
    done
    [[ -n "$pid" ]] && break
  fi
done
[[ -z "$pid" ]] && { print "  LAUNCH FAILED (no FPSWEEP window after 20s)"; exit 1 }
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
