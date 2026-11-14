#!/usr/bin/env python3
"""Time-compress an asciinema recording of a live Claude Code session for the README demo.

A real session spends most of its wall-clock time waiting on the model, and Claude Code's
spinner redraws the screen continuously, so asciinema/agg's idle-time limit never kicks in.
This script uses the recorded keystrokes to tell typing apart from waiting:

  - Typing (gaps between keystrokes shorter than --think-gap) plays at real speed, with any
    single pause capped at --max-pause.
  - Waiting (a stretch with no keystrokes longer than --think-gap: the agent working, or
    npm install) is played --speed times faster, and never longer than --max-wait seconds.

Nothing is removed or reordered: every frame of output is kept, only the clock changes. The
README caption should say the agent's working time is sped up.

Record with input capture so keystrokes are in the file:
  asciinema 3.x:  asciinema rec --capture-input demo.cast
  asciinema 2.x:  asciinema rec --stdin demo.cast

Reads asciinema v2 (absolute times) or v3 (relative intervals); writes v2 without input events.
"""
import argparse
import json
import sys


def load(path):
    with open(path, encoding="utf-8") as f:
        header = json.loads(f.readline())
        events = [json.loads(line) for line in f if line.strip()]
    version = header.get("version", 2)
    absolute = []
    t = 0.0
    for ev in events:
        if version >= 3:
            t += float(ev[0])
        else:
            t = float(ev[0])
        absolute.append((t, ev[1], ev[2]))
    if version >= 3:
        term = header.get("term", {})
        header = {
            "version": 2,
            "width": term.get("cols", 100),
            "height": term.get("rows", 30),
            "timestamp": header.get("timestamp"),
            "env": {"TERM": term.get("type", "xterm-256color")},
        }
    header = {k: v for k, v in header.items() if v is not None}
    return header, absolute


def waiting_windows(events, think_gap):
    """Return (start, end) spans with no keystrokes for longer than think_gap."""
    inputs = [t for t, kind, _ in events if kind == "i"]
    if not inputs:
        sys.exit(
            "compress-cast: no input events found. Re-record with --capture-input "
            "(asciinema 3) or --stdin (asciinema 2) so typing can be told apart from waiting."
        )
    end = events[-1][0]
    marks = inputs + [end]
    windows = []
    prev = 0.0
    for t in marks:
        if t - prev > think_gap:
            windows.append((prev, t))
        prev = t
    return windows


def compress(events, windows, speed, max_wait, max_pause):
    out = []
    clock = 0.0
    prev_t = 0.0
    w = 0
    for t, kind, data in events:
        # Advance the output clock across the real interval [prev_t, t], split by windows.
        cursor = prev_t
        gap_out = 0.0
        while cursor < t:
            while w < len(windows) and windows[w][1] <= cursor:
                w += 1
            if w < len(windows) and windows[w][0] <= cursor < windows[w][1]:
                seg_end = min(t, windows[w][1])
                start, stop = windows[w]
                scale = min(1.0 / speed, max_wait / (stop - start))
                gap_out += (seg_end - cursor) * scale
            else:
                seg_end = min(t, windows[w][0]) if w < len(windows) else t
                gap_out += min(seg_end - cursor, max_pause)
            cursor = seg_end
        clock += gap_out
        prev_t = t
        if kind == "i":
            continue
        out.append([round(clock, 6), kind, data])
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--think-gap", type=float, default=2.5,
                   help="seconds without a keystroke that count as waiting (default 2.5)")
    p.add_argument("--speed", type=float, default=8.0,
                   help="speed-up applied to waiting stretches (default 8)")
    p.add_argument("--max-wait", type=float, default=4.0,
                   help="longest any single waiting stretch may play, in seconds (default 4)")
    p.add_argument("--max-pause", type=float, default=1.0,
                   help="longest pause while typing, in seconds (default 1)")
    a = p.parse_args()

    header, events = load(a.input)
    if not events:
        sys.exit("compress-cast: recording has no events")
    windows = waiting_windows(events, a.think_gap)
    out = compress(events, windows, a.speed, a.max_wait, a.max_pause)

    with open(a.output, "w", encoding="utf-8") as f:
        f.write(json.dumps(header) + "\n")
        for ev in out:
            f.write(json.dumps(ev) + "\n")

    before = events[-1][0]
    after = out[-1][0] if out else 0.0
    waited = sum(e - s for s, e in windows)
    print(f"compress-cast: {before:.0f}s -> {after:.0f}s "
          f"({len(windows)} waiting stretches, {waited:.0f}s of waiting sped up)")


if __name__ == "__main__":
    main()
