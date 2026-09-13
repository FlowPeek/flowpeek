#!/bin/zsh
# What happens to the hint box when the rows move under it.
#
# Two ways rows move, and they are not the same. Output arriving walks the diagram up the screen,
# which is what a coding agent does all day. The reader scrolling back moves the view over a buffer
# that is standing still. A frame is drawn over rows, so both have to put it somewhere new.
#
# Synthetic wheel events do not move Ghostty at all -- measured -- so neither is faked with one.
set -e
FPHERE=${0:a:h}
source "$FPHERE/lib.sh"
mode=${1:-output}; shape=${2:-agent}; font=${3:-14}; lead=${4:-0}; ticks=${5:-3}
fp_tools
if ! fp_launch "$shape" no "$font" "$lead"; then
  print "  LAUNCH FAILED (no FPSWEEP window)"
  exit 1
fi

look() {
  print -n "  $1: "
  fp_look "$shape" "$FPHERE/scroll-$1" || true
}

look 0
for tick in $(seq 1 $ticks); do
  case $mode in
    # More output, the way an agent produces it: the printer is asked for three more rows and the
    # diagram walks up the screen.
    output) [[ -n "$FPPRINTER" ]] && kill -USR1 $FPPRINTER 2>/dev/null ;;
    # The reader dragging the scrollbar back over a buffer that is standing still.
    back)   "$FPHERE/scrollto" $FPPID $(print "scale=2; 1 - $tick / 10" | bc) >/dev/null 2>&1 ;;
  esac
  look $tick
done
kill $FPPID 2>/dev/null || true
for attempt in $(seq 1 20); do
  kill -0 $FPPID 2>/dev/null || break
  sleep 0.25
done
