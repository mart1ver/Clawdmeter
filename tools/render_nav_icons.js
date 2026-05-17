#!/usr/bin/env node
// Render 4 Lucide-style SVGs to 40x40 PNGs for the bottom nav buttons.
// The png_to_lvgl pipeline expects black-on-transparent or any-colour-on-
// transparent — only the alpha plane matters because the converter tints.
// We hard-code white here so a raw PNG looks right too.

const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const SIZE = 40;
const COLOR = '#FFFFFF';
const OUT_DIR = path.join(__dirname, '..', 'assets');

const wrap = (body) => `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="${COLOR}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;

const icons = {
    'bar-chart-2': wrap(`
        <line x1="18" y1="20" x2="18" y2="10"/>
        <line x1="12" y1="20" x2="12" y2="4"/>
        <line x1="6" y1="20" x2="6" y2="14"/>
    `),
    'cpu': wrap(`
        <rect x="4" y="4" width="16" height="16" rx="2"/>
        <rect x="9" y="9" width="6" height="6"/>
        <line x1="9" y1="2" x2="9" y2="4"/>
        <line x1="15" y1="2" x2="15" y2="4"/>
        <line x1="9" y1="20" x2="9" y2="22"/>
        <line x1="15" y1="20" x2="15" y2="22"/>
        <line x1="20" y1="9" x2="22" y2="9"/>
        <line x1="20" y1="14" x2="22" y2="14"/>
        <line x1="2" y1="9" x2="4" y2="9"/>
        <line x1="2" y1="14" x2="4" y2="14"/>
    `),
    'bitcoin': wrap(`
        <path d="M11.767 19.089c4.924.868 6.14-6.025 1.216-6.894m-1.216 6.894L5.86 18.047m5.908 1.042-.347 1.97m1.563-8.864c4.924.869 6.14-6.025 1.215-6.893m-1.215 6.893-3.94-.694m5.155-6.2L8.29 4.26m5.908 1.042.348-1.97M7.48 20.364l3.126-17.727"/>
    `),
    'power': wrap(`
        <path d="M12 2v10"/>
        <path d="M18.4 6.6a9 9 0 1 1-12.77.04"/>
    `),
};

(async () => {
    for (const [name, svg] of Object.entries(icons)) {
        const out = path.join(OUT_DIR, `icon_${name}_${SIZE}.png`);
        await sharp(Buffer.from(svg))
            .resize(SIZE, SIZE)
            .png()
            .toFile(out);
        console.log(`Wrote ${out}`);
    }
})();
