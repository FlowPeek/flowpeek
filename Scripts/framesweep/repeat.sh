#!/bin/zsh
# Run one case several times and check that every run says exactly the same thing.
#
# This is the check on the harness rather than on FlowPeek. A measurement that changes between two
# identical runs cannot be used to decide whether a change to the product broke something, and this
# harness has been wrong that way twice: once because it measured a window that was still closing,
# once because it captured a chip mid-fade. Both looked like product failures. So before a result is
# believed, the case it came from is run again and the answers are compared character for character.
#
#   repeat.sh <times> <shape> <no|alt> <font size> <leading rows>
set -e
FPHERE=${0:a:h}
times=${1:-3}; shape=${2:-agent}; screen=${3:-no}; font=${4:-14}; lead=${5:-0}
work=$(mktemp -d)
trap 'rm -rf $work' EXIT
print "== $times x  shape=$shape screen=$screen font=$font lead=$lead"
for run in $(seq 1 $times); do
  "$FPHERE/sweep.sh" $shape $screen $font $lead > "$work/$run" 2>/dev/null || true
  print -n "  run $run: "
  head -1 "$work/$run"
done
same=1
for run in $(seq 2 $times); do
  if ! diff -q "$work/1" "$work/$run" >/dev/null; then
    same=0
    print ""
    print "  DIFFERS on run $run:"
    diff "$work/1" "$work/$run" | sed 's/^/    /'
  fi
done
print ""
if (( same )); then
  print "  STABLE  $times runs, identical"
  exit 0
fi
print "  UNSTABLE  the harness does not give the same answer twice"
exit 1
