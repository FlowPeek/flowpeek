#!/bin/zsh
# What happens to the hint box when the rows move under it.
#
# Two ways rows move, and they are not the same. Output arriving walks the diagram up the screen,
# which is what a coding agent does all day. The reader scrolling back moves the view over a buffer
# that is standing still. A frame is drawn over rows, so both have to put it somewhere new.
#
# Synthetic wheel events do not move Ghostty at all -- measured -- so neither is faked with one.
set -e
HERE=${0:a:h}
: ${FPTINT:=009E73}
: ${FPUSER:=1510}
mode=${1:-output}; shape=${2:-agent}; font=${3:-14}; lead=${4:-0}; ticks=${5:-3}
for tool in bands overlay point scrollto; do
  [[ -x "$HERE/$tool" ]] || swiftc -O "$HERE/$tool.swift" -o "$HERE/$tool"
done

/usr/bin/open -na /Applications/Ghostty.app --args --font-size=$font --title=FPSWEEP \
  --command="/usr/bin/python3 $HERE/sweepprint.py $shape no $lead"
sleep 5
pid=$(pgrep -x ghostty | grep -v "^$FPUSER$" | head -1)
[[ -z "$pid" ]] && { print "  LAUNCH FAILED"; exit 1 }
printer=$(cat /tmp/fpsweep-pid 2>/dev/null)
/usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set size of window 1 to {1180, 880}" >/dev/null 2>&1
sleep 2
/usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $pid) to set frontmost to true" >/dev/null 2>&1
sleep 6

look() {
  local label=$1
  local snapshot win out
  snapshot=$($HERE/overlay)
  win=$(print "$snapshot" | grep '^window ' | head -1 | cut -d' ' -f2)
  out=$(print "$snapshot" | grep '^outline ' | head -1 | cut -d' ' -f2)
  IFS=, read wx wy ww wh <<< "$win"
  if [[ -n "$out" ]]; then
    IFS=, read ox oy ow oh <<< "$out"
    "$HERE/point" $(( ${ox%.*} + ${ow%.*} / 2 )) $(( ${oy%.*} + ${oh%.*} / 2 )) >/dev/null 2>&1
    sleep 2
  fi
  /usr/sbin/screencapture -x -R ${wx%.*},${wy%.*},${ww%.*},${wh%.*} "$HERE/scroll-$label.png"
  local bands=$($HERE/bands "$HERE/scroll-$label.png" 2 --tint=$FPTINT)
  print -n "  $label: "
  /usr/bin/python3 "$HERE/verdict.py" "$shape" "$win" "${out:-none}" "$bands" || true
}

look 0
for tick in $(seq 1 $ticks); do
  case $mode in
    output) [[ -n "$printer" ]] && kill -USR1 $printer 2>/dev/null; sleep 2 ;;
    back)   "$HERE/scrollto" $pid $(print "scale=2; 1 - $tick / 10" | bc) >/dev/null 2>&1; sleep 2 ;;
  esac
  look $tick
done
kill $pid 2>/dev/null || true
