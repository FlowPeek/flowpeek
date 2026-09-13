#!/bin/zsh
# The cases the first matrix does not reach: wide cells, a diagram taller than the window, one the
# reader has scrolled part of the way past, and two diagrams on one screen.
FPHERE=${0:a:h}
source "$FPHERE/lib.sh"
run() {
  print "== shape=$1 screen=$2 font=$3 lead=$4"
  local out
  out=$("$FPHERE/sweep.sh" $1 $2 $3 $4 2>&1) || true
  print -r -- "$out"
  fp_tally "$out"
}
# Korean: two cells to a character, which is what the reported window had.
for font in 12 16 20 24; do run korean no $font 0; done
for font in 14 20; do run korean alt $font 0; done
# Taller than any window, so the read has to widen at one end or both.
for lead in 0 10 30; do run long no 14 $lead; done
# Pushed down the screen until the top of the block is above the viewport.
for lead in 20 34 40; do run agent no 14 $lead; done
# Two blocks on one screen: each frame is measured against its own block's markers, not counted.
for font in 12 16 20; do run two no $font 0; done
fp_totals
