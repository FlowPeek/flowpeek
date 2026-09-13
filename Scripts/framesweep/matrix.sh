#!/bin/zsh
# Output shape x screen kind x font size.
FPHERE=${0:a:h}
source "$FPHERE/lib.sh"
for shape in agent fenced plain; do
  for screen in no alt; do
    for font in 12 14 20 24; do
      print "== shape=$shape screen=$screen font=$font lead=0"
      out=$("$FPHERE/sweep.sh" $shape $screen $font 0 2>&1) || true
      print -r -- "$out"
      fp_tally "$out"
    done
  done
done
fp_totals
