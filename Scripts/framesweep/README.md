# The frame sweep

Checks, on screen, that the outline FlowPeek draws in a terminal is around the diagram and not
somewhere near it.

It exists because the faults that matter here are invisible to a unit test. A row height remembered
from another font, a window resized after its output was printed, a pty whose bracket never closes:
each of those produced a frame that was drawn confidently in the wrong place, and each was found by
looking at a screenshot rather than by reading the code. `swift test` pins what the scanner makes of
rows that are handed to it; this pins what the reader sees.

## How it decides

Nothing FlowPeek believes is used. The printer puts a coloured row immediately above **each** block
and another immediately below it:

```
[blue]     ← one row above the first marker, so the pitch is
             measurable when the top has scrolled away
[magenta]  ← one row, immediately above block 0
  mermaid
  flowchart TD          ┐
      A --> B           │ block 0
      ...               ┘
[cyan]     ← one row, immediately below it
[magenta]  ← and again for block 1, where there is one
  mermaid
  sequenceDiagram       ┐ block 1
      ...               ┘
[cyan]
[yellow]   ← one row below the last marker, so the row pitch is
             measurable when the diagram is taller than the window
```

A pair per block rather than one pair around everything, because that is the only way to say which
frame belongs to which diagram. Two markers, two frames, paired top to bottom.

The checker finds those bands in the screenshot by their colour, takes the row pitch from the
distance between two bands' **centres** — centres rather than edges, because a band's edges are
anti-aliased and measuring them put the pitch out by a third in some captures and not others — and
works out where the block is. `AmbientHighlight.inset` is 5 points, so a correct outline is the
block's rectangle grown by 5 on every side. A case passes when both edges are within one row.

Where the diagram is taller than the window, the top marker has scrolled away; that edge is then
checked for not claiming rows above the window rather than against a marker, and the yellow band
carries the pitch.

The hint box is the frame **and** the chip that names the diagram and says which key opens it, so
the chip is checked too. It only appears once the pointer is near, so every frame is looked at again
with the pointer on it, and the chip is found by the hint tint: the tallest block of tinted pixels
that is wider than a glyph and narrower than half the window, searched only in the rows around the
frame being asked about. All three bounds are load-bearing -- without the width limit the finder
picks the frame's own hairline, which runs the whole width of the terminal; without the row limit it
picks whichever of two chips happens to be taller.

## Does the checker work

A suite that has only ever said PASS proves nothing about a build; it may just be unable to say
anything else. `selftest.py` feeds the checker screens that are made up rather than captured — one
correct, then the same one broken in each of the ways a real fault would break it: the frame a row
too low, the frame swallowing the label row above the diagram, the chip missing, the chip floating
off the frame, one frame drawn around both diagrams, and the two frames **swapped** so that each
sits on the other's diagram. That last one is the case the old two-diagram check could not see at
all, because it counted frames instead of locating them.

It needs no terminal, no app and no window server, so it runs anywhere in about a second, and the
battery runs it first — if the checker cannot reject a wrong screen, nothing after it means
anything.

## Why it does not sleep

Nothing here waits a fixed number of seconds for a result. A sweep that sleeps and then measures
gives one answer on an idle machine and another on a busy one, and both look equally confident --
this harness has been wrong that way twice, once measuring a window that was still closing and once
capturing a chip mid-fade, and both times the product was fine. So it polls for the state it needs,
bounded, and says so when the state never arrives: for the window to exist, for the set of frames to
stop changing, for the chip to have faded in.

Two other rules follow from the same idea. The terminal window is given a fixed position as well as
a fixed size, so the coordinates in a report do not depend on where macOS felt like cascading it.
And a case that produces no verdict at all counts as a **failure**, not as silence -- counting only
the lines that said PASS or FAIL is how two launch failures once vanished from a battery's totals
and left it reading clean.

`repeat.sh` is the check on all of that: it runs one case several times and compares the reports
character for character.

## Running it

Needs a Debug build installed and granted Accessibility — `zsh Scripts/install_debug_app.sh` — and
Ghostty. It opens and closes its own terminal windows and touches nothing else.

```sh
python3 Scripts/framesweep/selftest.py   # the checker's own cases; no app or terminal needed
zsh Scripts/framesweep/all.sh       # everything below, in order
zsh Scripts/framesweep/matrix.sh    # output shape x screen x font size
zsh Scripts/framesweep/matrix2.sh   # wide cells, a diagram taller than the window, scrolled past
zsh Scripts/framesweep/scroll.sh back agent 14 60 4   # the frame across five scroll positions
zsh Scripts/framesweep/sweep.sh agent alt 20 0        # one case
zsh Scripts/framesweep/repeat.sh 4 two no 16 0       # the same case four times, must agree
```

`sweep.sh <shape> <no|alt> <font size> <leading rows>`, where the shape is `agent` (no fence, a dim
`mermaid` label and a two-space margin, the way a coding agent prints one), `fenced`, `plain`,
`korean` (two cells to a character), `long` (taller than any window) or `two` (two diagrams at
once, which must get two separate frames).

`scroll.sh <back|output> <shape> <font size> <leading rows> <ticks>` checks the same thing while the
rows are moving: `back` scrolls the reader up the scrollback, so the diagram's bottom leaves the
window a row at a time; `output` prints further rows, so the diagram climbs the window under the
frame. Each tick is checked on its own, and a tick where neither marker is left on screen is skipped
rather than guessed at.

## What it has caught

- A frame drawn from a row height remembered for another font, on a pane whose own grid ruled it out.
- A bracket refused for being three pixels wide, on a pane where nothing else could ever narrow it.
- Every join refused after a window was resized, because the pty reported the new width while the
  rows on screen still carried the old one.
- An `erDiagram` joined into two lines, because `||--o{` was read as an opened bracket.
- A row height solved from the pane's own measurements, one pixel under what the pty said the cell
  was, at one scroll position out of five. The frame there covered the label row above the diagram
  and cut the last line off the bottom. The terminal is asked first now and the solver is held to
  its answer.
- The padding that followed from that: pinning the solved row height to the pty's without also
  taking the pty's padding pushed the mismatch into the leftover and moved a frame fourteen points
  down the screen, its top edge through the declaration.

## What it has got wrong itself

Worth recording, because each of these would have passed a broken build or failed a working one, and
every one was found by looking at the capture rather than at the number:

- Measuring a band by its edges rather than its centre made the row pitch wander by a third between
  captures, because the edges are anti-aliased.
- FlowPeek's own hairline crossing a band split it in two, and the first half read as a row half
  again too tall. Runs closer than ten pixels are one band now, and the tallest band wins.
- A large font left the top marker off screen. The window is grown to 1180x880 and the printer
  repaints on `SIGWINCH`.
- Two diagrams on one screen were checked by **counting** frames, not by locating them: the case
  passed as long as two frames existed anywhere. A build that drew the right number of frames in the
  wrong two places would have passed it. Each block carries its own markers now.
- The chip finder took the longest run of tint, which is the frame's edge, not the chip; then
  grouping rows by where their run started split the pill into slivers, because the white text
  through its middle moves the run. Height is what tells a pill from a hairline.
- The tint the chip is found by was hard-coded to the default green, and the default is not what
  anyone runs. The first sweep against a real installation reported the chip missing on all
  twenty-four cases; that app is set to `#CC79A7` and the finder was hunting for `#009E73`. The
  frame was exactly where it belonged in every one of them. The tint now comes from the defaults
  domain of whichever build is running -- a tint is the reader's choice, an input to the test rather
  than a thing under test, and the geometry is still measured off the screen.
- Waiting a fixed five seconds for a terminal to open put two cases of twenty-four onto the previous
  case's window, which was still closing, and failed them for a fault that reproduced nowhere on its
  own. It waits for a window to actually be there now.
