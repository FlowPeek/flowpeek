#!/bin/zsh
# Everything, in the order it was learned to be needed.
HERE=${0:a:h}
print "===== shapes, screens, font sizes ====="
"$HERE/matrix.sh"
print ""
print "===== wide cells, taller than the window, pushed down, two at once ====="
"$HERE/matrix2.sh"
print ""
print "===== output arriving, so the rows move under the frame ====="
for lead in 44 60; do
  print -r -- "-- lead=$lead"
  "$HERE/scroll.sh" output agent 14 $lead 4
done
print ""
print "===== the reader scrolling back, so the diagram's bottom goes off screen ====="
for lead in 60 80; do
  print -r -- "-- lead=$lead"
  "$HERE/scroll.sh" back agent 14 $lead 4
done
