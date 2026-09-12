#!/bin/zsh
# The cases the first matrix does not reach: wide cells, a diagram taller than the window, and one
# the reader has scrolled part of the way past.
HERE=${0:a:h}
pass=0; fail=0; skip=0
run() {
  print "== shape=$1 screen=$2 font=$3 lead=$4"
  out=$("$HERE/sweep.sh" $1 $2 $3 $4 2>&1) || true
  print "$out"
  [[ "$out" == *PASS* ]] && ((pass++))
  [[ "$out" == *FAIL* ]] && ((fail++))
  [[ "$out" == *SKIP* ]] && ((skip++))
}
# Korean: two cells to a character, which is what the reported window had.
for font in 12 16 20 24; do run korean no $font 0; done
for font in 14 20; do run korean alt $font 0; done
# Taller than any window, so the read has to widen at one end or both.
for lead in 0 10 30; do run long no 14 $lead; done
# Pushed down the screen until the top of the block is above the viewport.
for lead in 20 34 40; do run agent no 14 $lead; done
print ""
print "PASS $pass  FAIL $fail  SKIP $skip"
