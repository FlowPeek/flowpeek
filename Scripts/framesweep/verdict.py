"""Turn a window rect, an outline rect and the marker bands into a pass or a fail.

The bands are the ground truth. Each marker row is exactly one row tall and sits immediately above
and below the printed block, so the row pitch is the distance between the two bands' CENTRES over
the number of rows between them -- centres rather than edges, because a band's edges are
anti-aliased and measuring them put the row height out by a third in some captures and not others.

`AmbientHighlight.inset` is 5 points, so a correct outline is the block's rectangle grown by 5 on
every side.
"""
import sys

INSET = 5.0
# How many printed rows sit between the top marker and the block itself, and below it.
BEFORE = {"agent": 1, "korean": 1, "long": 1, "fenced": 0, "plain": 0}
AFTER = {"agent": 0, "korean": 0, "long": 0, "fenced": 0, "plain": 0}

def band(text, key):
    """The centre of the tallest band of this colour, which is the marker row; anything smaller is
    a fragment of it or a stray match."""
    for line in text.split("\n"):
        if line.startswith(key + " ") and line[len(key) + 1:].strip():
            spans = []
            for span in line[len(key) + 1:].strip().split(","):
                top, bottom = span.split("-")
                spans.append((float(bottom) - float(top), (float(top) + float(bottom)) / 2))
            return max(spans)[1]
    return None

shape, window, outline, bands = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
wx, wy, ww, wh = [float(v) for v in window.split(",")]
top_marker, bottom_marker = band(bands, "magenta"), band(bands, "cyan")
pitch_marker = band(bands, "yellow")
try:
    printed = int(open("/tmp/fpsweep-rows").read().strip())
except Exception:
    printed = None

if top_marker is None and bottom_marker is None:
    print("  SKIP  neither marker is on screen")
    sys.exit(0)
# The row pitch, from whichever pair of bands is on screen. The yellow band sits exactly one row
# below the bottom marker, so it measures the pitch even when the diagram is taller than the window
# and the top of it has scrolled away -- which is the case worth checking, not one to skip.
if top_marker is not None and bottom_marker is not None and printed:
    row = (bottom_marker - top_marker) / (printed + 1)
elif bottom_marker is not None and pitch_marker is not None:
    row = pitch_marker - bottom_marker
else:
    print(f"  SKIP  cannot measure the row pitch (top={top_marker} bottom={bottom_marker} pitch={pitch_marker})")
    sys.exit(0)

want_top = (wy + top_marker + row / 2 + row * BEFORE[shape] - INSET) if top_marker is not None else None
want_bottom = (wy + bottom_marker - row / 2 - row * AFTER[shape] + INSET) if bottom_marker is not None else None

if outline == "none":
    print(f"  FAIL  no outline drawn (row {row:.1f})")
    sys.exit(1)
ox, oy, ow, oh = [float(v) for v in outline.split(",")]
parts, ok = [], True
if want_top is not None:
    dt = oy - want_top
    ok = ok and abs(dt) <= row
    parts.append(f"top{dt:+.0f}")
else:
    # The block runs off the top of the window, so the frame's top edge belongs to the viewport.
    # What has to be right is that it does not claim rows above the window.
    ok = ok and oy >= wy - row
    parts.append("top=clipped")
if want_bottom is not None:
    db = (oy + oh) - want_bottom
    ok = ok and abs(db) <= row
    parts.append(f"bottom{db:+.0f}")
else:
    ok = ok and (oy + oh) <= wy + wh + row
    parts.append("bottom=clipped")
print(f"  {'PASS' if ok else 'FAIL'}  row={row:.1f} rows={printed} {' '.join(parts)} "
      f"(outline {oy:.0f}..{oy + oh:.0f})")
sys.exit(0 if ok else 1)
