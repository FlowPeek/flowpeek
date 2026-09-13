#!/bin/zsh
# One case: put a terminal on screen, let FlowPeek settle, and check every frame it drew against the
# markers around the diagram that frame is supposed to be on.
#
# Exits non-zero when the case fails, so a caller can tell a failure from a case that said nothing.
set -e
FPHERE=${0:a:h}
source "$FPHERE/lib.sh"
shape=$1; screen=$2; font=$3; lead=$4
fp_tools
if ! fp_launch "$shape" "$screen" "$font" "$lead"; then
  print "  FAIL  no FPSWEEP window ever appeared"
  exit 1
fi
result=0
verdict=$(fp_look "$shape" "$FPHERE/case") || result=$?
kill $FPPID 2>/dev/null || true
print -r -- "$verdict"
# Wait for it to actually go, so the next case cannot measure this window.
for attempt in $(seq 1 20); do
  kill -0 $FPPID 2>/dev/null || break
  sleep 0.25
done
exit $result
