#!/usr/bin/env python3
"""Print a diagram into a terminal in one of several shapes, with markers that make the
diagram's first and last row findable in a screenshot without reading anything else."""
import fcntl, os, signal, struct, sys, termios, time

MARGIN = "  "
KOREAN = """flowchart TD
    A[사용자 요청] --> B{인증됨?}
    B -- 예 --> C[요청 처리]
    B -- 아니오 --> D[로그인 페이지]
    D --> E[자격증명 입력]
    E --> B
    C --> F{캐시 히트?}
    F -- 예 --> G[캐시 응답]
    F -- 아니오 --> H[DB 조회]
    H --> I[캐시 저장]
    I --> G
    G --> J([응답 반환])"""

LONG = "flowchart TD\n" + "\n".join(
    f'    S{i:03d}["stage {i:03d} of a diagram taller than any window"] --> S{i+1:03d}'
    for i in range(1, 121)
)

DIAGRAM = """flowchart TD
    A["stage one of the pipeline"] --> B{"is it cached"}
    B -- yes --> C["serve from cache"]
    B -- no --> D["query the database"]
    D --> E["write to the cache"]
    E --> C
    C --> F["return the response"]
    F --> G["record the timing"]
    G --> H["close the connection"]
    H --> I(["done"])"""

def columns():
    packed = fcntl.ioctl(sys.stdout.fileno(), termios.TIOCGWINSZ, struct.pack("HHHH", 0, 0, 0, 0))
    return struct.unpack("HHHH", packed)[1]

def wrap(line, width):
    out, rest = [], line
    while len(rest) > width:
        cut = rest.rfind(" ", 0, width + 1)
        if cut <= 0:
            out.append(rest[:width]); rest = rest[width:]
        else:
            out.append(rest[:cut]); rest = rest[cut + 1:]
    out.append(rest)
    return out

SECOND = """sequenceDiagram
    participant A as Reader
    participant B as FlowPeek
    A->>B: points at a diagram
    B-->>A: draws a frame around it
    A->>B: holds Option and clicks
    B-->>A: opens the picture"""

def blocks(shape, width):
    """The diagram blocks to print, each as its own list of rows.

    A list rather than one flat run of rows because a screen with two diagrams on it has to be
    checked the way a reader sees it: each block gets its own pair of marker rows, so each frame is
    measured against the diagram it is supposed to be around rather than against the pair of them.
    Counting frames -- which is all this did before -- passes a build that draws two frames in the
    wrong two places.
    """
    source = {"korean": KOREAN, "long": LONG}.get(shape, DIAGRAM)
    if shape == "two":
        out = []
        for block in (DIAGRAM, SECOND):
            rows = [MARGIN + "mermaid"]
            for line in block.split("\n"):
                rows.extend(wrap(MARGIN + line, width))
            out.append(rows)
        return out
    if shape in ("agent", "korean", "long"):
        rows = [MARGIN + "mermaid"]
        for line in source.split("\n"):
            rows.extend(wrap(MARGIN + line, width))
        return [rows]
    if shape == "fenced":
        return [["```mermaid"] + source.split("\n") + ["```"]]
    return [source.split("\n")]

def show(*_):
    width = columns()
    groups = blocks(SHAPE, width)
    # The checker needs to know how many rows sit between each pair of markers; counting them off a
    # screenshot would be guessing, and this is the one thing only the printer knows. One count per
    # block, in the order they are printed.
    open("/tmp/fpsweep-rows", "w").write(",".join(str(len(g)) for g in groups))
    # And its own pid, so the harness can ask for more output without having to guess which process
    # to signal -- matching the command line also matches the terminal that launched it, and a
    # stray SIGUSR1 kills the terminal.
    open("/tmp/fpsweep-pid", "w").write(str(os.getpid()))
    if ALTERNATE:
        sys.stdout.write("\033[?1049h")
    sys.stdout.write("\033[2J\033[H")
    for i in range(LEAD):
        print(f"LEADIN{i:03d} ordinary output before the diagram")
    # Marker rows in colours nothing else on screen uses, so a screenshot can be measured
    # without reading any of the text in it.
    # A band one row above the top marker, so the row pitch is measurable when the reader has
    # scrolled back and the bottom of the diagram is below the window.
    print("\033[48;2;0;0;255m" + "FPSWEEP-PITCH".ljust(width) + "\033[0m")
    # One pair of markers per block. Where there are two, block one's bottom marker and block two's
    # top marker are adjacent rows; they stay apart in the reading because they are different
    # colours, and each is found by its own colour rather than by its position.
    for index, group in enumerate(groups):
        print("\033[48;2;255;0;255m" + f"FPSWEEP-TOP-{index}".ljust(width) + "\033[0m")
        for row in group:
            print(row)
        print("\033[48;2;0;255;255m" + f"FPSWEEP-BOTTOM-{index}".ljust(width) + "\033[0m")
    # A third band one row below the bottom marker, so the row pitch can be measured even when the
    # diagram is taller than the window and the top marker is off screen.
    print("\033[48;2;255;255;0m" + f"cols={width} shape={SHAPE}".ljust(width) + "\033[0m")
    sys.stdout.flush()

if __name__ == "__main__":
    SHAPE = sys.argv[1]
    ALTERNATE = len(sys.argv) > 2 and sys.argv[2] == "alt"
    LEAD = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    # Reprint whenever the window changes size, so the harness can grow the window until everything
    # it needs to measure is on screen.
    signal.signal(signal.SIGWINCH, show)
    # More output on demand, which is how a terminal really scrolls: the agent keeps talking and the
    # diagram walks up the screen. Synthetic wheel events do not move Ghostty at all.
    signal.signal(signal.SIGUSR1, lambda *_: (
        [print(f"TRAILING{n:03d} more output after the diagram") for n in range(3)],
        sys.stdout.flush(),
    ))
    show()
    while True:
        time.sleep(60)
