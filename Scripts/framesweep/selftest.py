#!/usr/bin/env python3
"""Does the checker actually reject a wrong screen?

A suite that has only ever said PASS proves nothing about a build; it may just be unable to say
anything else. So the checker is fed screens that are made up rather than captured -- one correct,
and then the same one broken in each of the ways a real fault would break it -- and has to get every
one right. This needs no terminal, no app and no window server, so it runs anywhere and in a second.
"""
import os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
WINDOW = "0,0,1180,880"
ROW = 17.0
INSET = 5.0


def screen(blocks):
    """Marker bands for blocks given as (top marker centre, row count), plus the frames that would
    be exactly right for them."""
    magenta, cyan, frames, counts = [], [], [], []
    for centre, rows in blocks:
        low = centre + ROW * (rows + 1)
        magenta.append(f"{centre - 4}-{centre + 4}")
        cyan.append(f"{low - 4}-{low + 4}")
        # agent shape: one label row between the marker and the diagram, nothing below.
        top = centre + ROW / 2 + ROW - INSET
        bottom = low - ROW / 2 + INSET
        frames.append((10.0, top, 1000.0, bottom - top))
        counts.append(rows)
    bands = "\n".join([
        "magenta " + ",".join(magenta),
        "cyan " + ",".join(cyan),
        "yellow ",
        "blue ",
    ])
    return bands, frames, counts


def chip_for(frame):
    ox, oy, ow, oh = frame
    return f"{ox + ow - 110},{oy + 5},{ox + ow - 6},{oy + 25}"


def run(shape, frames, bands, chips, counts):
    with tempfile.NamedTemporaryFile("w", suffix=".rows", delete=False) as handle:
        handle.write(",".join(str(c) for c in counts))
        path = handle.name
    try:
        joined = ";".join(",".join(f"{v}" for v in f) for f in frames) if frames else "none"
        result = subprocess.run(
            [sys.executable, os.path.join(HERE, "verdict.py"), shape, WINDOW, joined, bands,
             ";".join(chips)],
            capture_output=True, text=True, env={**os.environ, "FPSWEEP_ROWS": path},
        )
        return result.stdout.strip()
    finally:
        os.unlink(path)


CASES = []


def case(name, expect):
    def register(build):
        CASES.append((name, expect, build))
        return build
    return register


@case("one block, frame exactly right", "PASS")
def _():
    bands, frames, counts = screen([(100, 11)])
    return "agent", frames, bands, [chip_for(frames[0])], counts


@case("one block, frame a row too low", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11)])
    ox, oy, ow, oh = frames[0]
    moved = (ox, oy + ROW * 1.5, ow, oh)
    return "agent", [moved], bands, [chip_for(moved)], counts


@case("one block, frame swallowing the label row", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11)])
    ox, oy, ow, oh = frames[0]
    grown = (ox, oy - ROW * 1.5, ow, oh + ROW * 1.5)
    return "agent", [grown], bands, [chip_for(grown)], counts


@case("one block, no chip", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11)])
    return "agent", frames, bands, ["none"], counts


@case("one block, chip floating off the frame", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11)])
    ox, oy, ow, oh = frames[0]
    return "agent", frames, bands, [f"{ox + 20},{oy + 300},{ox + 124},{oy + 320}"], counts


@case("two blocks, both frames right", "PASS")
def _():
    bands, frames, counts = screen([(100, 11), (420, 8)])
    return "two", frames, bands, [chip_for(f) for f in frames], counts


@case("two blocks, one frame around both", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11), (420, 8)])
    whole = (10.0, frames[0][1], 1000.0, frames[1][1] + frames[1][3] - frames[0][1])
    return "two", [whole], bands, [chip_for(whole)], counts


@case("two blocks, frames swapped", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11), (420, 8)])
    a, b = frames
    # Same two rectangles, each on the other's diagram: the shape counting frames could not see this.
    swapped = [(a[0], a[1], a[2], b[3]), (b[0], b[1], b[2], a[3])]
    return "two", swapped, bands, [chip_for(f) for f in swapped], counts


@case("two blocks, second frame missing", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11), (420, 8)])
    return "two", [frames[0]], bands, [chip_for(frames[0])], counts


@case("two blocks, second block's chip missing", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11), (420, 8)])
    return "two", frames, bands, [chip_for(frames[0]), "none"], counts


@case("two blocks, both chips on the first frame", "FAIL")
def _():
    bands, frames, counts = screen([(100, 11), (420, 8)])
    return "two", frames, bands, [chip_for(frames[0]), chip_for(frames[0])], counts


failures = 0
for name, expect, build in CASES:
    shape, frames, bands, chips, counts = build()
    got = run(shape, frames, bands, chips, counts)
    verdict = got.split()[0] if got else "<nothing>"
    if verdict == expect:
        print(f"  ok    {name}")
    else:
        failures += 1
        print(f"  WRONG {name}: expected {expect}, got {verdict}")
        print(f"        {got}")
print()
print(f"{len(CASES) - failures}/{len(CASES)} of the checker's own cases correct")
sys.exit(1 if failures else 0)
