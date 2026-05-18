#!/usr/bin/env python3
"""Generate nav button pictograms for the Clawdmeter.

Outputs firmware/src/nav_pictograms.h with 3 small 20x20 animated icons that
match the nav buttons' meaning:
  - system   : 5 vertical EQ bars pulsing (cyan + dim cyan top)
  - bitcoin  : Bitcoin B-with-stems glyph in orange that pulses
  - actions  : 3x2 grid of dots, one bright at a time (matches the 6 action
               buttons on the Actions tab, cycles cyan/orange)

Re-run after editing: python3 tools/gen_nav_pictograms.py
"""

import sys
from pathlib import Path

GRID = 20


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def palette_to_c(pal):
    vals = [f"0x{rgb565(r, g, b):04X}" for r, g, b in pal]
    while len(vals) < 10:
        vals.append("0x0000")
    return "{" + ", ".join(vals) + "}"


def frame_to_c(grid, indent="        "):
    return ",\n".join(indent + ", ".join(str(v) for v in row) for row in grid)


# ----------------------------------------------------------------------------
# 1. System: equalizer bars (5 vertical bars at varying heights per frame)
# ----------------------------------------------------------------------------
def gen_system_eq():
    palette = [
        (0, 0, 0),          # 0 bg (replaced at render)
        (0x00, 0xD9, 0xFF), # 1 bright cyan (main bar)
        (0x00, 0x6C, 0x80), # 2 dim cyan (bar top / shadow)
        (0xd9, 0x77, 0x57), # 3 orange accent (peak indicator)
        (0xff, 0xff, 0xff), # 4 white (unused, reserved)
    ]

    # Each row = one frame, each value = bar height (1..18 cells).
    # 6 frames staggered so each bar peaks at a different time -> smooth loop.
    heights_per_frame = [
        [10, 14,  6, 12,  8],
        [12, 11,  8, 14,  6],
        [14,  8, 12, 10, 10],
        [10,  6, 14,  8, 12],
        [ 8, 10, 11, 12, 14],
        [ 6, 12, 10, 14, 11],
    ]

    frames = []
    for hs in heights_per_frame:
        g = [[0] * GRID for _ in range(GRID)]
        for i, h in enumerate(hs):
            x = 1 + i * 4
            # main bar body in bright cyan
            for y in range(GRID - h, GRID):
                for dx in range(3):
                    g[y][x + dx] = 1
            # top cap of bar in dim cyan (gradient)
            top = GRID - h
            for dx in range(3):
                g[top][x + dx] = 2
            # peak indicator (orange) on the topmost cell when bar is at max
            if h >= 14:
                g[top][x + 1] = 3
        frames.append(g)

    holds = [180] * len(frames)
    return palette, frames, holds


# ----------------------------------------------------------------------------
# 2. Bitcoin: stylized B-with-stems glyph that pulses
# ----------------------------------------------------------------------------
# Classic Bitcoin mark: letter B with two short vertical strokes extending
# above the top bar AND below the bottom bar. The stems align with the
# B's right-bump verticals so the eye reads them as one continuous shape.
# Designed to read clearly at 40x40 (cell=2).
# ----------------------------------------------------------------------------
def gen_bitcoin_coin():
    palette = [
        (0, 0, 0),          # 0 bg
        (0xf7, 0x93, 0x1a), # 1 bright BTC orange
        (0xa0, 0x5b, 0x10), # 2 dim orange (shadow)
        (0xff, 0xc8, 0x70), # 3 light orange (highlight)
        (0xff, 0xff, 0xff), # 4 white
    ]

    # Bigger, bolder Bitcoin "B" with two short stems above + below.
    # Layout:
    #   B body at x=2..17 (16 wide), y=3..14 (12 tall)
    #     - left vertical  x=2..5
    #     - gap            x=6..13
    #     - right vertical x=14..17
    #     - bars at y=3-4 (top), y=8-9 (middle), y=13-14 (bottom)
    #   Stems centered on the left+right verticals at x=3-4 and x=15-16
    #     - top stems    y=1..2
    #     - bottom stems y=15..16
    # Stems align with B verticals so the eye reads continuous strokes.
    GLYPH = [
        "....................",  # y=0
        "...##..........##...",  # y=1  top stems (aligned to verticals)
        "...##..........##...",  # y=2
        "..################..",  # y=3  top bar (full B width)
        "..################..",  # y=4
        "..####........####..",  # y=5  left + gap + right
        "..####........####..",  # y=6
        "..####........####..",  # y=7
        "..################..",  # y=8  middle bar
        "..################..",  # y=9
        "..####........####..",  # y=10
        "..####........####..",  # y=11
        "..####........####..",  # y=12
        "..################..",  # y=13 bottom bar
        "..################..",  # y=14
        "...##..........##...",  # y=15 bottom stems
        "...##..........##...",  # y=16
        "....................",  # y=17
        "....................",  # y=18
        "....................",  # y=19
    ]

    def render(lines, color):
        g = [[0] * GRID for _ in range(GRID)]
        for y, line in enumerate(lines):
            for x, ch in enumerate(line):
                if ch == '#':
                    g[y][x] = color
        return g

    # 6 frames: pulse cycle (bright -> highlight -> bright -> dim -> bright -> highlight)
    frames = [
        render(GLYPH, 1),  # bright
        render(GLYPH, 3),  # light highlight
        render(GLYPH, 1),  # bright
        render(GLYPH, 2),  # dim shadow
        render(GLYPH, 1),  # bright
        render(GLYPH, 3),  # highlight
    ]
    holds = [260, 120, 260, 200, 260, 120]
    return palette, frames, holds


# ----------------------------------------------------------------------------
# 3. Actions: 3x2 grid of dots, one bright at a time
# ----------------------------------------------------------------------------
# Directly maps to the 6 buttons on the Actions tab. At any moment one dot
# is "active" (bright); the others are dim. Sequences through all 6 over
# time like a running-light / step sequencer. Conveys "buttons / trigger"
# without needing a literal icon.
# ----------------------------------------------------------------------------
def gen_actions_grid():
    palette = [
        (0, 0, 0),          # 0 bg
        (0x00, 0xD9, 0xFF), # 1 bright cyan (active)
        (0x00, 0x4a, 0x60), # 2 dim cyan (idle)
        (0xf7, 0x93, 0x1a), # 3 bright orange (alt active)
        (0xa8, 0x4d, 0x2c), # 4 dim orange (alt idle)
    ]

    # 3 columns x 2 rows. Each dot is a 4x5 rectangle.
    DOT_W, DOT_H = 4, 5
    COL_X = [1, 8, 15]      # left edge of each column
    ROW_Y = [3, 12]         # top edge of each row

    # Per-dot color scheme matches the Actions tab itself:
    # cyan/orange alternating (1=cyan,2=orange,3=cyan,4=orange,...)
    DOT_BRIGHT = [1, 3, 1, 3, 1, 3]
    DOT_DIM    = [2, 4, 2, 4, 2, 4]

    def draw_dot(g, col, row, color):
        x0 = COL_X[col]
        y0 = ROW_Y[row]
        for dy in range(DOT_H):
            for dx in range(DOT_W):
                y, x = y0 + dy, x0 + dx
                if 0 <= y < GRID and 0 <= x < GRID:
                    g[y][x] = color

    # Reading order: top-row left-to-right, then bottom-row left-to-right.
    sequence = [(0, 0), (1, 0), (2, 0), (0, 1), (1, 1), (2, 1)]

    frames = []
    for active_idx in range(6):
        g = [[0] * GRID for _ in range(GRID)]
        for i, (col, row) in enumerate(sequence):
            color = DOT_BRIGHT[i] if i == active_idx else DOT_DIM[i]
            draw_dot(g, col, row, color)
        frames.append(g)

    holds = [180] * 6
    return palette, frames, holds


# ----------------------------------------------------------------------------
# Emit C header
# ----------------------------------------------------------------------------
def emit_pictogram(out, id_name, display_name, palette, frames, holds):
    n = len(frames)
    out.append("")
    out.append(f"// ---- {display_name} ----")
    out.append(f"static const uint16_t nav_pict_{id_name}_palette[10] = {palette_to_c(palette)};")
    out.append(f"static const uint8_t nav_pict_{id_name}_frames[{n}][400] = {{")
    for i, g in enumerate(frames):
        out.append(f"    {{  // frame {i}")
        out.append(frame_to_c(g, "        "))
        out.append("    },")
    out.append("};")
    out.append(f"static const uint16_t nav_pict_{id_name}_holds[{n}] = {{")
    out.append("    " + ", ".join(str(h) for h in holds))
    out.append("};")


def main():
    out = []
    out.append("#pragma once")
    out.append("// ============================================================")
    out.append("// Nav button pictograms - generated by tools/gen_nav_pictograms.py")
    out.append("// 20x20 indexed-palette frames, same layout as splash anims so")
    out.append("// clawd_thumb can render them with the existing pipeline.")
    out.append("// Do not edit by hand - re-run the generator.")
    out.append("// ============================================================")
    out.append("#include <stdint.h>")
    out.append("")
    out.append("#define NAV_PICT_GRID         20")
    out.append("#define NAV_PICT_PALETTE_SIZE 10")
    out.append("")
    out.append("typedef struct {")
    out.append("    const char     *name;")
    out.append("    uint16_t        frame_count;")
    out.append("    const uint16_t *palette;             // [10] RGB565")
    out.append("    const uint8_t (*frames)[400];        // [N][400] palette indices")
    out.append("    const uint16_t *holds;               // [N] ms per frame")
    out.append("} nav_pict_def_t;")

    pictograms = []

    pal, fr, hl = gen_system_eq()
    emit_pictogram(out, "system_eq", "System - equalizer bars", pal, fr, hl)
    pictograms.append(("system eq", "system_eq", len(fr)))

    pal, fr, hl = gen_bitcoin_coin()
    emit_pictogram(out, "bitcoin_coin", "Bitcoin - pulsing B glyph", pal, fr, hl)
    pictograms.append(("bitcoin coin", "bitcoin_coin", len(fr)))

    pal, fr, hl = gen_actions_grid()
    emit_pictogram(out, "actions_bolt", "Actions - 3x2 dot sequencer", pal, fr, hl)
    pictograms.append(("actions bolt", "actions_bolt", len(fr)))

    out.append("")
    out.append(f"#define NAV_PICT_COUNT {len(pictograms)}")
    out.append("static const nav_pict_def_t nav_pictograms[NAV_PICT_COUNT] = {")
    for name, id_name, n in pictograms:
        out.append(f"    {{\"{name}\", {n}, nav_pict_{id_name}_palette, nav_pict_{id_name}_frames, nav_pict_{id_name}_holds}},")
    out.append("};")
    out.append("")

    dst = Path(__file__).resolve().parent.parent / "firmware" / "src" / "nav_pictograms.h"
    dst.write_text("\n".join(out))
    print(f"Wrote {dst} ({len(out)} lines, {len(pictograms)} pictograms)")


if __name__ == "__main__":
    main()
