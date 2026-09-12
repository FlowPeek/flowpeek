#!/usr/bin/env python3
"""Print a diagram into a terminal in one of several shapes, with markers that make the
diagram's first and last row findable in a screenshot without reading anything else."""
import fcntl, signal, struct, sys, termios, time

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

def body(shape, width):
    source = {"korean": KOREAN, "long": LONG}.get(shape, DIAGRAM)
    rows = []
    if shape in ("agent", "korean", "long"):
        rows.append(MARGIN + "mermaid")
        for line in source.split("\n"):
            rows.extend(wrap(MARGIN + line, width))
    elif shape == "fenced":
        rows.append("```mermaid")
        rows.extend(source.split("\n"))
        rows.append("```")
    else:  # plain
        rows.extend(source.split("\n"))
    return rows

def show(*_):
    width = columns()
    rows = body(SHAPE, width)
    # The checker needs to know how many rows sit between the markers; counting them off a
    # screenshot would be guessing, and this is the one thing only the printer knows.
    open("/tmp/fpsweep-rows", "w").write(str(len(rows)))
    if ALTERNATE:
        sys.stdout.write("\033[?1049h")
    sys.stdout.write("\033[2J\033[H")
    for i in range(LEAD):
        print(f"LEADIN{i:03d} ordinary output before the diagram")
    # Marker rows in colours nothing else on screen uses, so a screenshot can be measured
    # without reading any of the text in it.
    print("\033[48;2;255;0;255m" + "FPSWEEP-TOP".ljust(width) + "\033[0m")
    for row in rows:
        print(row)
    print("\033[48;2;0;255;255m" + "FPSWEEP-BOTTOM".ljust(width) + "\033[0m")
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
    show()
    while True:
        time.sleep(60)
