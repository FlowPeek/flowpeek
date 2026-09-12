#!/bin/zsh
HERE=${0:a:h}
pass=0; fail=0; skip=0
for shape in agent fenced plain; do
  for screen in no alt; do
    for font in 12 14 20 24; do
      print "== shape=$shape screen=$screen font=$font lead=0"
      if out=$("$HERE/sweep.sh" $shape $screen $font 0 2>&1); then
        print "$out"
        [[ "$out" == *PASS* ]] && ((pass++))
        [[ "$out" == *SKIP* ]] && ((skip++))
      else
        print "$out"; ((fail++))
      fi
    done
  done
done
print ""
print "PASS $pass  FAIL $fail  SKIP $skip"
