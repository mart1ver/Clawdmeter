#!/usr/bin/env python3
"""Generate nav button pictograms for the Clawdmeter.

Outputs firmware/src/nav_pictograms.h with 3 small 20x20 animated icons that
match the nav buttons' meaning:
  - system   : 5 vertical EQ bars pulsing (cyan + dim cyan top)
  - bitcoin  : Bitcoin ₿ glyph in orange that pulses
  - actions  : lightning bolt cycling cyan → white flash → orange flash

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
    # 6 frames staggered so each bar peaks at a different time → smooth loop.
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
# 2. Bitcoin: stylized ₿ glyph with pulsing brightness
# ----------------------------------------------------------------------------
def gen_bitcoin_coin():
    palette = [
        (0, 0, 0),          # 0 bg
        (0xf7, 0x93, 0x1a), # 1 bright BTC orange
        (0xa0, 0x5b, 0x10), # 2 dim orange (shadow)
        (0xff, 0xc8, 0x70), # 3 light orange (highlight on pulse)
        (0xff, 0xff, 0xff), # 4 white
    ]

    # Hand-drawn ₿ glyph: a filled rounded square containing a white B with
    # two short vertical strokes sticking out of the top and bottom (the
    # Bitcoin stem). Designed to read clearly at 40x40 px (cell=2).
    #
    # Legend: . = bg, # = orange fill, _ = bg cutout (forms the B's negative)
    GLYPH = [
        "....................",
        "....................",
        "......##.....##.....",
        "......##.....##.....",
        "....##############..",
        "....##############..",
        "....####.....#####..",
        "....####.....#####..",
        "....####.....#####..",
        "....##############..",
        "....##############..",
        "....####.....#####..",
        "....####.....#####..",
        "....####.....#####..",
        "....##############..",
        "....##############..",
        "......##.....##.....",
        "......##.....##.....",
        "....................",
        "....................",
    ]

    def render(glyph_lines, fill_color, outline_color=None):
        g = [[0] * GRID for _ in range(GRID)]
        for y, line in enumerate(glyph_lines):
            for x, ch in enumerate(line):
                if ch == '#':
                    g[y][x] = fill_color
        # Optional 1-cell outline (dim orange) around the filled area
        if outline_color is not None:
            outline = [row[:] for row in g]
            for y in range(GRID):
                for x in range(GRID):
                    if g[y][x] == 0:
                        # Touches a filled cell horizontally or vertically?
                        for dy, dx in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                            ny, nx = y + dy, x + dx
                            if 0 <= ny < GRID and 0 <= nx < GRID and g[ny][nx] == fill_color:
                                outline[y][x] = outline_color
                                break
            g = outline
        return g

    # 6 frames: smooth pulse cycle.
    # bright → very bright → bright → dim → bright → very bright
    frames = [
        render(GLYPH, fill_color=1),              # bright
        render(GLYPH, fill_color=3),              # peak (light highlight)
        render(GLYPH, fill_color=1),              # bright
        render(GLYPH, fill_color=2),              # dim shadow
        render(GLYPH, fill_color=1),              # bright
        render(GLYPH, fill_color=3),              # peak again
    ]
    holds = [240, 100, 240, 200, 240, 100]
    return palette, frames, holds


# ----------------------------------------------------------------------------
# 3. Actions: lightning bolt with electric flash cycle
# ----------------------------------------------------------------------------
def gen_actions_bolt():
    palette = [
        (0, 0, 0),          # 0 bg
        (0x00, 0xD9, 0xFF), # 1 bright cyan
        (0x00, 0x6C, 0x80), # 2 dim cyan
        (0xf7, 0x93, 0x1a), # 3 orange flash
        (0xff, 0xff, 0xff), # 4 white flash core
    ]

    # Classic Z-shaped lightning bolt (centered, fills most of the canvas).
    BOLT = [
        "....................",
        "..........#####.....",
        ".........#####......",
        "........#####.......",
        ".......#####........",
        "......#####.........",
        ".....#####..........",
        "....##########......",
        "....##########......",
        "...##########.......",
        "...........###......",
        "..........###.......",
        ".........###........",
        "........###.........",
        ".......###..........",
        "......###...........",
        ".....###............",
        "....................",
        "....................",
        "....................",
    ]

    def make_bolt(color):
        g = [[0] * GRID for _ in range(GRID)]
        for y, line in enumerate(BOLT):
            for x, ch in enumerate(line):
                if ch == '#':
                    g[y][x] = color
        return g

    def add_sparks(g, color, positions):
        for (px, py) in positions:
            if 0 <= py < GRID and 0 <= px < GRID:
                g[py][px] = color
        return g

    frames = []
    # Frame 0: calm cyan bolt
    frames.append(make_bolt(1))
    # Frame 1: cyan bolt + tiny sparks in corners
    g = make_bolt(1)
    add_sparks(g, 1, [(2, 2), (17, 2), (2, 17), (17, 17)])
    frames.append(g)
    # Frame 2: white flash core
    frames.append(make_bolt(4))
    # Frame 3: orange flash with white sparks around
    g = make_bolt(3)
    add_sparks(g, 4, [(1, 4), (18, 4), (1, 15), (18, 15), (10, 0), (10, 19)])
    frames.append(g)
    # Frame 4: dim cyan bolt (afterglow)
    frames.append(make_bolt(2))
    # Frame 5: back to bright cyan with bigger sparks
    g = make_bolt(1)
    add_sparks(g, 4, [(3, 1), (16, 1), (3, 18), (16, 18)])
    frames.append(g)

    # Variable hold times: most of the cycle is "calm cyan", flashes are short.
    holds = [400, 120, 80, 100, 200, 150]
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
    out.append("// Nav button pictograms — generated by tools/gen_nav_pictograms.py")
    out.append("// 20x20 indexed-palette frames, same layout as splash anims so")
    out.append("// clawd_thumb can render them with the existing pipeline.")
    out.append("// Do not edit by hand — re-run the generator.")
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
    emit_pictogram(out, "system_eq", "System — equalizer bars", pal, fr, hl)
    pictograms.append(("system eq", "system_eq", len(fr)))

    pal, fr, hl = gen_bitcoin_coin()
    emit_pictogram(out, "bitcoin_coin", "Bitcoin — pulsing ₿ glyph", pal, fr, hl)
    pictograms.append(("bitcoin coin", "bitcoin_coin", len(fr)))

    pal, fr, hl = gen_actions_bolt()
    emit_pictogram(out, "actions_bolt", "Actions — lightning bolt", pal, fr, hl)
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
