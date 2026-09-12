# The frame sweep

Checks, on screen, that the outline FlowPeek draws in a terminal is around the diagram and not
somewhere near it.

It exists because the faults that matter here are invisible to a unit test. A row height remembered
from another font, a window resized after its output was printed, a pty whose bracket never closes:
each of those produced a frame that was drawn confidently in the wrong place, and each was found by
looking at a screenshot rather than by reading the code. `swift test` pins what the scanner makes of
rows that are handed to it; this pins what the reader sees.

## How it decides

Nothing FlowPeek believes is used. The printer puts a coloured row immediately above the block and
another immediately below it, and a third one row below that:

```
[magenta]  ← one row, immediately above the block
  mermaid
  flowchart TD          ┐
      A --> B           │ the block
      ...               ┘
[cyan]     ← one row, immediately below it
[yellow]   ← one row below that, so the row pitch is measurable
           when the diagram is taller than the window
```

The checker finds those bands in the screenshot by their colour, takes the row pitch from the
distance between two bands' **centres** — centres rather than edges, because a band's edges are
anti-aliased and measuring them put the pitch out by a third in some captures and not others — and
works out where the block is. `AmbientHighlight.inset` is 5 points, so a correct outline is the
block's rectangle grown by 5 on every side. A case passes when both edges are within one row.

Where the diagram is taller than the window, the top marker has scrolled away; that edge is then
checked for not claiming rows above the window rather than against a marker, and the yellow band
carries the pitch.

## Running it

Needs a Debug build installed and granted Accessibility — `zsh Scripts/install_debug_app.sh` — and
Ghostty. It opens and closes its own terminal windows and touches nothing else.

```sh
zsh Scripts/framesweep/matrix.sh    # output shape x screen x font size
zsh Scripts/framesweep/matrix2.sh   # wide cells, a diagram taller than the window, scrolled past
zsh Scripts/framesweep/sweep.sh agent alt 20 0   # one case
```

`sweep.sh <shape> <no|alt> <font size> <leading rows>`, where the shape is `agent` (no fence, a dim
`mermaid` label and a two-space margin, the way a coding agent prints one), `fenced`, `plain`,
`korean` (two cells to a character) or `long` (taller than any window).

## What it has caught

- A frame drawn from a row height remembered for another font, on a pane whose own grid ruled it out.
- A bracket refused for being three pixels wide, on a pane where nothing else could ever narrow it.
- Every join refused after a window was resized, because the pty reported the new width while the
  rows on screen still carried the old one.
- An `erDiagram` joined into two lines, because `||--o{` was read as an opened bracket.
