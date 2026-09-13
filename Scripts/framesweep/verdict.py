"""Turn a window rect, the frames FlowPeek drew and the marker bands into a pass or a fail.

The bands are the ground truth. Each block printed carries its own pair of marker rows, one row
immediately above it and one immediately below, so a screen with two diagrams on it is checked the
way a reader sees it: every frame is measured against the diagram it is supposed to be around.
Counting frames -- which is all the two-diagram case did before -- passes a build that draws the
right number of frames in the wrong places.

The row pitch comes from the distance between a pair of bands' CENTRES over the number of rows
between them; centres rather than edges, because a band's edges are anti-aliased and measuring them
put the row height out by a third in some captures and not others.

`AmbientHighlight.inset` is 5 points, so a correct frame is the block's rectangle grown by 5 on
every side.
"""
import sys

INSET = 5.0
# How many printed rows sit between a block's top marker and the diagram itself, and below it. The
# agent shapes print a dim `mermaid` label that FlowPeek does not frame.
BEFORE = {"agent": 1, "korean": 1, "long": 1, "two": 1, "fenced": 0, "plain": 0}
AFTER = {"agent": 0, "korean": 0, "long": 0, "two": 0, "fenced": 0, "plain": 0}


def centres(text, key):
    """The centre of every band of this colour, top to bottom.

    A band may arrive in pieces -- a glyph or FlowPeek's own hairline crossing it -- so pieces
    closer together than half a marker row are one band. Anything left that is too thin to be a
    marker row is dropped rather than paired with a block it does not belong to.
    """
    for line in text.split("\n"):
        if not line.startswith(key + " "):
            continue
        body = line[len(key) + 1:].strip()
        if not body:
            return []
        spans = []
        for span in body.split(","):
            top, bottom = span.split("-")
            spans.append((float(top), float(bottom)))
        spans.sort()
        merged = [list(spans[0])]
        for top, bottom in spans[1:]:
            if top - merged[-1][1] <= 6:
                merged[-1][1] = max(merged[-1][1], bottom)
            else:
                merged.append([top, bottom])
        tallest = max(b - t for t, b in merged)
        return [(t + b) / 2 for t, b in merged if (b - t) >= tallest / 2]
    return []


def rects(argument):
    """The frames, top to bottom. Ordering them by where they are is what lets a frame be paired
    with a block; the order they are read out of the window list is not meaningful."""
    if argument in ("none", ""):
        return []
    out = []
    for part in argument.split(";"):
        if not part.strip():
            continue
        out.append(tuple(float(v) for v in part.split(",")))
    return sorted(out, key=lambda r: r[1])


shape, window, outlines_arg, bands, chips_arg = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] if len(sys.argv) > 5 else ""
)
wx, wy, ww, wh = [float(v) for v in window.split(",")]
tops, bottoms = centres(bands, "magenta"), centres(bands, "cyan")
pitch_below, pitch_above = centres(bands, "yellow"), centres(bands, "blue")
outlines = rects(outlines_arg)
# One chip per frame, in the same order, each found inside the frame it belongs to. An empty entry
# means the chip was looked for there and not found.
chips = [c.strip() for c in chips_arg.split(";")] if chips_arg else []

# The printer leaves the row counts here. Overridable so the checker itself can be tested against
# made-up screens without a terminal on the desk.
import os
try:
    rows_path = os.environ.get("FPSWEEP_ROWS", "/tmp/fpsweep-rows")
    printed = [int(v) for v in open(rows_path).read().strip().split(",")]
except Exception:
    printed = []

if not tops and not bottoms:
    print("  SKIP  neither marker is on screen")
    sys.exit(0)

# Which blocks can be checked, and against what. The whole picture -- a marker pair for every block
# printed -- is the ordinary case and the only one where a frame can be paired with a block by
# position. Where markers have scrolled away the pairing stops being knowable, so it is only
# attempted for a single block, and anything else says so rather than guessing.
if len(tops) == len(bottoms) == len(printed) and printed:
    pairs = list(zip(tops, bottoms, printed))
elif len(printed) == 1:
    pairs = [(tops[0] if tops else None, bottoms[0] if bottoms else None, printed[0])]
else:
    print(f"  SKIP  {len(tops)} top and {len(bottoms)} bottom markers on screen "
          f"for {len(printed)} blocks -- cannot say which frame belongs to which")
    sys.exit(0)

# The row pitch, from whichever pair of bands is on screen. The yellow band sits exactly one row
# below the last bottom marker and the blue one exactly one row above the first top marker, so the
# pitch is still measurable when the diagram is taller than the window and one end has scrolled
# away -- which is the case worth checking, not one to skip.
row = None
for top, bottom, rows in pairs:
    if top is not None and bottom is not None and rows:
        row = (bottom - top) / (rows + 1)
        break
if row is None:
    if bottoms and pitch_below:
        row = pitch_below[-1] - bottoms[-1]
    elif tops and pitch_above:
        row = tops[0] - pitch_above[0]
if row is None or row <= 0:
    print(f"  SKIP  cannot measure the row pitch (tops={len(tops)} bottoms={len(bottoms)})")
    sys.exit(0)

if len(outlines) != len(pairs):
    print(f"  FAIL  {len(pairs)} block(s) but {len(outlines)} frame(s) (row {row:.1f})")
    sys.exit(1)

ok = True
reports = []
for index, ((top, bottom, rows), outline) in enumerate(zip(pairs, outlines)):
    ox, oy, ow, oh = outline
    want_top = (wy + top + row / 2 + row * BEFORE[shape] - INSET) if top is not None else None
    want_bottom = (wy + bottom - row / 2 - row * AFTER[shape] + INSET) if bottom is not None else None
    parts = []
    if want_top is not None:
        delta = oy - want_top
        ok = ok and abs(delta) <= row
        parts.append(f"top{delta:+.0f}")
    else:
        # The block runs off the top of the window, so the frame's top edge belongs to the viewport.
        # What has to be right is that it does not claim rows above the window.
        ok = ok and oy >= wy - row
        parts.append("top=clipped")
    if want_bottom is not None:
        delta = (oy + oh) - want_bottom
        ok = ok and abs(delta) <= row
        parts.append(f"bottom{delta:+.0f}")
    else:
        ok = ok and (oy + oh) <= wy + wh + row
        parts.append("bottom=clipped")
    # And the chip, which is the other half of the hint box: the pill that names the diagram and
    # says which key opens it. It has to sit on its own frame, not float near it or sit on another.
    chip = chips[index] if index < len(chips) else ""
    if not chip or chip == "none":
        parts.append("chip=absent")
        ok = False
    else:
        cl, ct, cr, cb = [float(v) for v in chip.split(",")]
        cl, ct, cr, cb = wx + cl, wy + ct, wx + cr, wy + cb
        on_top_edge = abs(ct - oy) <= row
        inside = cl >= ox - 2 and cr <= ox + ow + 2
        right_aligned = cr >= ox + ow - 6 * row
        placed = on_top_edge and inside and right_aligned
        ok = ok and placed
        parts.append(f"chip={'on' if placed else 'OFF'}"
                     f"({ct - oy:+.0f} from the top, right edge {ox + ow - cr:+.0f})")
    reports.append(f"[{index}] rows={rows} {' '.join(parts)} (outline {oy:.0f}..{oy + oh:.0f})")

label = "PASS" if ok else "FAIL"
if len(reports) == 1:
    print(f"  {label}  row={row:.1f} {reports[0][4:]}")
else:
    print(f"  {label}  row={row:.1f} {len(reports)} blocks")
    for report in reports:
        print(f"          {report}")
sys.exit(0 if ok else 1)
