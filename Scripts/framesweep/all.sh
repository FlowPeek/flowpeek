#!/bin/zsh
# Everything, in the order it was learned to be needed.
FPHERE=${0:a:h}
# First, because it needs nothing and takes a second: can the checker say anything but PASS? A
# suite that has only ever passed proves nothing about a build.
print "===== can the checker reject a wrong screen ====="
/usr/bin/python3 "$FPHERE/selftest.py" || { print "  the checker is broken; the rest would mean nothing"; exit 1 }
print ""
print "===== shapes, screens, font sizes ====="
"$FPHERE/matrix.sh"
print ""
print "===== wide cells, taller than the window, pushed down, two at once ====="
"$FPHERE/matrix2.sh"
print ""
print "===== output arriving, so the rows move under the frame ====="
for lead in 44 60; do
  print -r -- "-- lead=$lead"
  "$FPHERE/scroll.sh" output agent 14 $lead 4
done
print ""
print "===== the reader scrolling back, so the diagram's bottom goes off screen ====="
for lead in 60 80; do
  print -r -- "-- lead=$lead"
  "$FPHERE/scroll.sh" back agent 14 $lead 4
done
print ""
# And the check on the harness itself. A number that changes between two identical runs cannot be
# used to decide whether a change to the product broke something, so the battery proves its own
# repeatability rather than assuming it.
print "===== does the harness give the same answer twice ====="
"$FPHERE/repeat.sh" 3 agent no 14 0
"$FPHERE/repeat.sh" 3 two no 16 0
"$FPHERE/repeat.sh" 3 long no 14 0
