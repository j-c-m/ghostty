#!/usr/bin/env python3
"""Live GPU workload for Instruments / Metal HUD.

ghostty-bench never hits Metal. Run this inside a Ghostty window so every
vsync actually encodes cell_bg (one dirty cell per frame, ~60 Hz).

  sparse  — default-bg grid (alpha 0). This branch degenerates those
            instances; main still shades every pixel.
  opaque  — full-grid opaque RGB backgrounds, then the same 60 Hz tick.
            Exercises blend-off + instanced quads.

Attach the tracer, focus this window, then:

  python3 src/benchmark/cell_bg_trace.py sparse 8
  python3 src/benchmark/cell_bg_trace.py opaque 8

Same window size and font on both builds. Throttled to 60 Hz so parse
does not drown the draw.
"""

from __future__ import annotations

import shutil
import sys
import time


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "sparse"
    duration = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0
    if mode not in ("sparse", "opaque"):
        sys.stderr.write("usage: cell_bg_trace.py [sparse|opaque] [seconds]\n")
        sys.exit(2)

    cols, rows = shutil.get_terminal_size()
    out = sys.stdout
    frame_dt = 1.0 / 60.0

    def write(s: str) -> None:
        out.write(s)

    write("\x1b[?1049h\x1b[?25l\x1b[?12l\x1b[H\x1b[2J")
    try:
        if mode == "opaque":
            write("\x1b[48;2;36;36;52m")
            for y in range(rows):
                write(f"\x1b[{y + 1};1H" + (" " * cols))
            out.flush()
        else:
            write("\x1b[0m")
            out.flush()

        n = 0
        end = time.perf_counter() + duration
        while True:
            start = time.perf_counter()
            if start >= end:
                break
            if mode == "opaque":
                write(f"\x1b[1;1H\x1b[48;2;36;36;52m\x1b[38;2;220;220;220m{n}")
            else:
                write(f"\x1b[1;1H\x1b[0m{n}")
            out.flush()
            n += 1
            delay = frame_dt - (time.perf_counter() - start)
            if delay > 0:
                time.sleep(delay)
    finally:
        write("\x1b[0m\x1b[?25h\x1b[?1049l")
        out.flush()
        sys.stderr.write(f"cell_bg_trace mode={mode} frames={n} size={cols}x{rows}\n")


if __name__ == "__main__":
    main()
