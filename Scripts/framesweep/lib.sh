#!/bin/zsh
# The parts every sweep needs: which tint to look for, how to put a terminal on screen, and how to
# wait for something instead of hoping it has happened.
#
# Waiting is the whole of it. A sweep that sleeps a fixed number of seconds and then measures gives
# a different answer on a busy machine than on an idle one, and both answers look equally
# confident. Two runs have already been lost that way -- one to a terminal that was still closing
# when the next case measured it, one to a chip that had not faded in yet -- so nothing here sleeps
# for a result. It polls for the state it needs, bounded, and says so when the state never arrives.

: ${FPUSER:=1510}
# The hint tint, taken from the build under test rather than assumed.
#
# It was hard-coded to the default green, and the default is not what anyone is running: the first
# sweep against a real installation reported the chip missing on every case, because that app is set
# to #CC79A7 and the finder was hunting for #009E73. The frame was exactly where it should be in all
# of them. A tint is the reader's choice, so it is an input to the test, not a thing under test --
# the geometry is still measured off the screen and nothing FlowPeek computes is used.
: ${FPDOMAIN:=$(pgrep -f "FlowPeek Debug.app" >/dev/null && print com.selenehyun.FlowPeek.debug || print com.selenehyun.FlowPeek)}
: ${FPTINT:=$(defaults read $FPDOMAIN flowpeek.hint.tint 2>/dev/null | tr -d '#[:space:]')}
: ${FPTINT:=009E73}
# Where the terminal is put. Pinned rather than left to macOS, which cascades a new window a little
# further down each time it opens one: the frame's own coordinates are part of what gets reported,
# and they must not depend on how many windows were opened before this one.
: ${FPWINDOW:=1180,880}
: ${FPORIGIN:=60,60}

fp_tools() {
  for tool in bands overlay point scrollto; do
    [[ -x "$FPHERE/$tool" ]] || swiftc -O "$FPHERE/$tool.swift" -o "$FPHERE/$tool"
  done
}

# Open a terminal running the printer, and leave its pid in $FPPID. Returns non-zero if no window
# ever appears.
fp_launch() {
  local shape=$1 screen=$2 font=$3 lead=$4
  /usr/bin/open -na /Applications/Ghostty.app --args --font-size=$font --title=FPSWEEP \
    --command="/usr/bin/python3 $FPHERE/sweepprint.py $shape $screen $lead"
  # Wait for the window, not for a length of time. Run back to back, the previous terminal is still
  # closing when the next is asked for, and a stale pid put two of twenty-four cases into a failure
  # that reproduced nowhere on its own.
  FPPID=""
  local attempt candidate
  for attempt in $(seq 1 40); do
    sleep 0.5
    if [[ -n "$($FPHERE/overlay 2>/dev/null | grep '^window ')" ]]; then
      for candidate in $(pgrep -x ghostty); do
        [[ "$candidate" == "$FPUSER" ]] && continue
        FPPID=$candidate
      done
      [[ -n "$FPPID" ]] && break
    fi
  done
  [[ -z "$FPPID" ]] && return 1
  FPPRINTER=$(cat /tmp/fpsweep-pid 2>/dev/null)
  # Size and position together, so a large font still leaves both markers on screen and so the
  # numbers reported do not depend on where macOS felt like putting the window.
  /usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $FPPID) to set position of window 1 to {${FPORIGIN%,*}, ${FPORIGIN#*,}}" >/dev/null 2>&1
  /usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $FPPID) to set size of window 1 to {${FPWINDOW%,*}, ${FPWINDOW#*,}}" >/dev/null 2>&1
  /usr/bin/osascript -e "tell application \"System Events\" to tell (first process whose unix id is $FPPID) to set frontmost to true" >/dev/null 2>&1
  return 0
}

# Poll until the set of frames stops changing, and print that set. FlowPeek redraws as it reads the
# pane, so the first answer after a resize is not the settled one; three identical reads in a row
# is what "settled" means here.
fp_settle() {
  local previous="" current="" stable=0 attempt
  for attempt in $(seq 1 60); do
    current=$($FPHERE/overlay 2>/dev/null | grep '^outline ' | sort)
    if [[ -n "$current" && "$current" == "$previous" ]]; then
      (( stable += 1 ))
      if (( stable >= 3 )); then print -r -- "$current"; return 0; fi
    else
      stable=0
    fi
    previous=$current
    sleep 0.25
  done
  print -r -- "$current"
  return 0
}

# Measure one look at the screen and print a verdict line.
#
#   fp_look <shape> <png prefix>
#
# Every frame on screen is checked against its own block's markers, and every frame is hovered in
# turn so its own chip is found on it -- with two diagrams up, the taller pill is not necessarily
# the one being asked about.
fp_look() {
  local shape=$1 prefix=$2
  local snapshot win outs
  fp_settle >/dev/null
  snapshot=$($FPHERE/overlay)
  win=$(print -r -- "$snapshot" | grep '^window ' | head -1 | cut -d' ' -f2)
  if [[ -z "$win" ]]; then print "  NO WINDOW"; return 1; fi
  IFS=, read wx wy ww wh <<< "$win"
  # Top to bottom, so a frame can be paired with the block it is supposed to be around.
  outs=(${(f)"$(print -r -- "$snapshot" | grep '^outline ' | cut -d' ' -f2 | sort -t, -k2 -g)"})
  /usr/sbin/screencapture -x -R ${wx%.*},${wy%.*},${ww%.*},${wh%.*} "$prefix.png"
  local bands=$($FPHERE/bands "$prefix.png" 2)
  # Declared once, outside the loop: zsh prints a variable's value when `local` names it a second
  # time in the same scope, which put a stray "attempt=1" on stderr for every block after the first.
  local joined_outs="" joined_chips="" index=0 out
  local band_top band_bottom chip attempt
  for out in $outs; do
    [[ -z "$out" ]] && continue
    IFS=, read ox oy ow oh <<< "$out"
    [[ -n "$joined_outs" ]] && joined_outs="$joined_outs;"
    joined_outs="$joined_outs$out"
    # The chip only appears once the pointer is near its frame, so each frame is looked at with the
    # pointer on it. Moving the pointer is the reader's own gesture and changes nothing else.
    "$FPHERE/point" $(( ${ox%.*} + ${ow%.*} / 2 )) $(( ${oy%.*} + ${oh%.*} / 2 )) >/dev/null 2>&1
    # Poll for the chip rather than sleeping a fixed time and hoping: it fades in, and a capture
    # taken during the fade reports it absent on a build where it is perfectly placed.
    band_top=$(( ${oy%.*} - ${wy%.*} - 10 ))
    band_bottom=$(( ${oy%.*} - ${wy%.*} + 60 ))
    chip="none"
    for attempt in 1 2 3 4 5 6; do
      sleep 0.4
      /usr/sbin/screencapture -x -R ${wx%.*},${wy%.*},${ww%.*},${wh%.*} "$prefix-hover$index.png"
      chip=$($FPHERE/bands "$prefix-hover$index.png" 2 --tint=$FPTINT --within=$band_top,$band_bottom \
             | grep '^chip ' | cut -d' ' -f2)
      [[ -n "$chip" && "$chip" != "none" ]] && break
    done
    [[ -n "$joined_chips" ]] && joined_chips="$joined_chips;"
    joined_chips="$joined_chips${chip:-none}"
    (( index += 1 ))
  done
  /usr/bin/python3 "$FPHERE/verdict.py" "$shape" "$win" "${joined_outs:-none}" "$bands" "$joined_chips"
}

# Tallying, in one place and with one rule that matters: a case that produced no verdict at all is a
# FAIL, not a silence. Counting only the lines that say PASS or FAIL is how two launch failures once
# vanished from a battery's totals and left it reading clean.
FP_PASS=0; FP_FAIL=0; FP_SKIP=0
fp_tally() {
  local verdict
  verdict=$(print -r -- "$1" | grep -oE '^  (PASS|FAIL|SKIP)' | head -1 | tr -d ' ')
  case $verdict in
    PASS) (( FP_PASS += 1 )) ;;
    SKIP) (( FP_SKIP += 1 )) ;;
    *)    (( FP_FAIL += 1 )) ;;
  esac
}

fp_totals() {
  print ""
  print "PASS $FP_PASS  FAIL $FP_FAIL  SKIP $FP_SKIP"
  (( FP_FAIL == 0 ))
}
