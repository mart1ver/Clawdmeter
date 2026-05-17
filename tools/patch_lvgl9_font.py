#!/usr/bin/env python3
"""Patch lv_font_conv output (LVGL 8 format) for LVGL 9 compatibility.

lv_font_conv 1.5.x still emits files wrapped in `#if LVGL_VERSION_MAJOR >= 8`
and references the removed `lv_font_fmt_txt_glyph_cache_t` API. LVGL 9
silently compiles the result to an empty font (invisible glyphs). This
script strips the version guards, drops the cache, and adds the new fields
(release_glyph, kerning, static_bitmap, fallback, user_data).

Usage: patch_lvgl9_font.py <file.c> [<file.c> ...]
"""
import re
import sys


def patch(text: str) -> str:
    # 1. Remove the cache block.
    text = re.sub(
        r"#if LVGL_VERSION_MAJOR == 8\s*\n"
        r"/\*Store all the custom data of the font\*/\s*\n"
        r"static\s+lv_font_fmt_txt_glyph_cache_t cache;\s*\n"
        r"#endif\s*\n",
        "",
        text,
    )

    # 2. Collapse the font_dsc wrapper to the LVGL 9 form.
    text = re.sub(
        r"#if LVGL_VERSION_MAJOR >= 8\s*\n"
        r"(static const lv_font_fmt_txt_dsc_t font_dsc = \{)\s*\n"
        r"#else\s*\n"
        r"static lv_font_fmt_txt_dsc_t font_dsc = \{\s*\n"
        r"#endif\s*\n",
        r"\1\n",
        text,
    )

    # 3. Drop the .cache = &cache field.
    text = re.sub(
        r"#if LVGL_VERSION_MAJOR == 8\s*\n"
        r"\s*\.cache = &cache\s*\n"
        r"#endif\s*\n",
        "",
        text,
    )

    # 4. Collapse the lv_font_t wrapper.
    text = re.sub(
        r"#if LVGL_VERSION_MAJOR >= 8\s*\n"
        r"(const lv_font_t \w+ = \{)\s*\n"
        r"#else\s*\n"
        r"lv_font_t \w+ = \{\s*\n"
        r"#endif\s*\n",
        r"\1\n",
        text,
    )

    # 5. Unwrap the subpx field AND inject the three new fields right after.
    text = re.sub(
        r"#if !\(LVGL_VERSION_MAJOR == 6 && LVGL_VERSION_MINOR == 0\)\s*\n"
        r"(\s*\.subpx = LV_FONT_SUBPX_NONE,)\s*\n"
        r"#endif\s*\n",
        r"\1\n    .release_glyph = NULL,\n    .kerning = 0,\n    .static_bitmap = 0,\n",
        text,
    )

    # 6. Unwrap the underline block.
    text = re.sub(
        r"#if LV_VERSION_CHECK\(7, 4, 0\) \|\| LVGL_VERSION_MAJOR >= 8\s*\n"
        r"(\s*\.underline_position = -?\d+,\s*\n"
        r"\s*\.underline_thickness = \d+,)\s*\n"
        r"#endif\s*\n",
        r"\1\n",
        text,
    )

    # 7. Unwrap the fallback field.
    text = re.sub(
        r"#if LV_VERSION_CHECK\(8, 2, 0\) \|\| LVGL_VERSION_MAJOR >= 9\s*\n"
        r"(\s*\.fallback = NULL,)\s*\n"
        r"#endif\s*\n",
        r"\1\n",
        text,
    )

    return text


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: patch_lvgl9_font.py <file.c> [...]")
    for path in sys.argv[1:]:
        with open(path) as f:
            src = f.read()
        out = patch(src)
        if out == src:
            print(f"{path}: no changes (already patched?)")
        else:
            with open(path, "w") as f:
                f.write(out)
            print(f"{path}: patched")
