# OSB brand guide

This guide covers OSB (the bot) and OSB Manager (the app) on osb.lol, in the bot panel, in the apps, in the GitHub READMEs and social previews, and in the admin panel. The mark is the **OSB seal**, chosen on 2026-11-02. The seal replaces the eight-point star, which read as a religious symbol.

## The seal

A merchant's seal, like the marks stamped on goods along the Silk Road: a cinnabar stamp in a gold frame, with carved letters. Top to bottom it reads **O**, then **S B**.

| File | Use |
| --- | --- |
| `osb-mark.svg` | The mark: the site header (above the ribbon), the footer, READMEs, social previews. viewBox `-70 -70 140 140`. |
| `osb-mark-small.svg` | The mark at 16 to 32 px, on a 32 px pixel grid: favicon, bot panel title bar, Tampermonkey icon, admin favicon. |
| `osb-manager-icon.svg` | The macOS app icon master: the seal on the dark-leather tile in the 1024 px icon grid. |
| `osb-manager-icon-windows.svg` | The Windows app icon at 40 to 256 px: the seal alone. |
| `osb-manager-icon-small.svg` | The Windows app icon at 16 to 32 px. It is the same drawing as `osb-mark-small.svg`. |

All five files come from `scripts/icon/build-brand.py`. Change the geometry or the colours there, not in the SVG files, and run it again. `--site <osb-site>` also writes the `#emblem` symbol and the favicon of the site. `scripts/make-icon.py` then renders `src/OsbManager/app.ico` and `docs/macos/app-icon-1024.png`.

### Construction

The unit is the seal's half width, 66 (the seal is 132 × 132 in a 140 viewBox).

- **Body:** a square with corner radius 6. The top right corner is cut at 45°, 16 % of the half width (about 10.5). This chipped corner is the seal's signature; it is always top right.
- **Frame:** gold, 10 wide, with a 2 px dark outline (`#2a1d08`). The cinnabar field is inset 10. A gold hairline (1 px, 45 % opacity) runs 4 inside the field.
- **Letters:** one stroke width (9.5) with round joins, in a 94-wide letter box (field minus a padding of 9).
  - **O:** a stadium 66 % of the box wide and 47 % high, centred, with full round ends. It must read as a letter, never as a bar or a slot.
  - **S and B:** below a gap of 10 % of the box. S takes the left 44 % and B the right 44 %. S has round turns; B has a straight spine and two round bowls.
- **Light:** a soft white ellipse at the top of the field (35 % opacity). A drop shadow is allowed under the whole seal; no other effects.
- **Small (16 to 32 px):** `osb-mark-small.svg` redraws the seal on a 32 px grid. Every edge is on an even unit, so the art is pixel-sharp at 16 and 32 px. The O is a 20 × 8 ring, and S and B are 8 × 10 pixel letters. Use this file, never a scaled-down large mark, at 32 px and below. At 24 px it is slightly soft, as any 32 px grid is.

## Colours

| Name | Hex | Role |
| --- | --- | --- |
| Cinnabar top | `#c24a32` | Seal field, top of the gradient; the top of the "Yakında" badge |
| Cinnabar (token `--cinnabar`) | `#8a3020` | Seal field, middle; the middle of the header ribbon band and the stamp badges |
| Cinnabar deep | `#5d1f14` | Seal field, bottom; the ribbon tails; the bottom of the Destek button |
| Cinnabar bright (`--cinnabar-bright`) | `#e0806a` | Warnings and errors as text on dark |
| Gold ink | `#f2d57e` | Seal letters and the hairline (`--gold-bright`) |
| Gold gradient | `#fff0bf` → `#e2bb5c` → `#9a7228` → `#e9c66c` | The seal frame (`g-gold` on the site) |
| Gold | `#c9a24a` | Lines, ornaments, small labels (`--gold`) |
| Gold deep | `#7d5f22` | Shade only (`--gold-deep`) |
| Turquoise | `#2aa39f`, bright `#5fd0c9`, deep `#12514f` | Accent: the section jewels and links |
| Leather | `#0c0a08` (soot), `#1a140f` (lacquer), tile `#3a2a1b` → `#100b07` | Backgrounds and the macOS tile |
| Parchment | `#ecdfc3` | Body text on dark |

The seal's gradient uses the site's own reds, so the seal, the Destek button and the "Yakında" badge are one family.

### Contrast rules

Ratios are WCAG 2.2 contrast ratios.

| Pair | Ratio | Rule |
| --- | --- | --- |
| Gold ink on cinnabar `#8a3020` | 5.78 | Text on cinnabar uses gold ink or white (8.32), never gold `#c9a24a` (3.47). |
| Gold ink on cinnabar top `#c24a32` | 3.38 | Only for marks and bold labels of 18 px and up; body text on cinnabar sits on `#8a3020` or darker. |
| Parchment on soot | 14.97 | Body text. |
| Gold ink on soot | 13.74 | Titles and the seal letters on dark. |
| Turquoise `#2aa39f` on soot | 6.44 | Links and accents. |
| Cinnabar `#8a3020` on soot | 2.38 | Never text, never a thin line on dark. Cinnabar is a fill behind gold or white; use `#e0806a` (7.03) for red text. |
| Gold `#e2bb5c` on white | 1.83 | Gold never stands alone on white or light grey. On light grounds, show the seal with its dark outline, or put it on a leather plate. |

## Type

- **Cinzel** (700, 900; SIL OFL 1.1) for wordmarks, the ribbon text ("AÇIK KAYNAK", "OPEN SOURCE") and display titles in capitals. In an image or an icon, convert Cinzel to outlines; a live font must never be needed to render a mark. `python scripts/icon/text-to-path.py <font.woff2> <word>` prints a word as one SVG path.
- **Alegreya** (700) for headlines and section titles on the site.
- **Barlow** (400, 600) for body text and **Barlow Condensed** (700) for labels and buttons: the site's sans.
- The seal letters are geometry, not a font. Do not set "OSB" in Cinzel or any other font inside a seal.

Use only fonts under the SIL OFL or a similar free licence.

## The stamp motif

A small seal stamp (the small mark, or a plain cinnabar square with the chipped corner and one gold word) may mark things as **from OSB**, or as one short status:

- **Use it for:** the brand spot in a title bar or a panel header; one status badge per item ("Yakında", "Yeni", a release version); a seal on a social preview or a README banner; a stamp on a download or release card.
- **Do not use it:** as a bullet, a list marker or a decoration repeated down a page; on every heading; behind body text; for warnings or errors (use `#e0806a` text and the warning icon); more than once in the same view next to the full seal; rotated, or in any colour but cinnabar and gold.

### Stamp badges on osb.lol

Every status badge on the site uses one style, `.badge` in `osb-site/src/styles/ornaments.css`:

- a 2 px gold rim (the seal's frame gradient) with a dark inner line, and the chipped corner, top right, cut at 45°;
- carved letters: Barlow Condensed 700, capitals, a dark line above and a faint light line below;
- worn ink: a few small dark specks and two soft dark patches on the field, so no two badges look printed;
- **cinnabar** (`#9a3624` → `#8a3020` → `#6e2618`, gold ink `#f2d57e`, at least 4.99:1) for status: "Yakında", "Yeni"/"New" on the newest changelog release, the 404 code (`.is-lg`);
- **gold** (`.is-gold`: `#f2d57e` → `#d9b25a` → `#c99a3a`, ink `#4a1a10`, at least 5.65:1) for the release version on the news slide.

The section titles keep the turquoise jewel, and the primary button stays gold; both were chosen on purpose. The header ribbon under the seal is cinnabar (the badge gradient) with a gold frame, a 0.8 gold hairline at 45 % opacity and gold Cinzel letters, so the seal and the ribbon read as one piece.

### Share art

`python scripts/brand/build-share-art.py --bot ../osb --write-site` renders, with Edge, from `osb-mark.svg`, the site's fonts, leather and filigree corners:

| File | Size | Where |
| --- | --- | --- |
| `docs/brand/readme-header.jpg` | 2560 × 640 | The top of this repository's README |
| `docs/brand/social-preview.jpg` | 1280 × 640 | GitHub social preview of `corevider/osb-manager` (Settings > General) |
| `osb/docs/brand/readme-header.jpg`, `social-preview.jpg` | same | The same for `corevider/osb`; `osb-mark-small.svg` is copied there for the bot panel and the userscript `@icon` |
| `osb-site/public/og-tr.jpg`, `og-en.jpg` | 1200 × 630 | `og:image` per language |
| `osb-site/public/apple-touch-icon.png` | 180 × 180 | The seal on leather, opaque, for iOS home screens |

The OSB Manager About box (Windows) shows the `.ico`'s 256 px seal at 96 px. The macOS About panel shows the app icon. The admin panel (`osb-platform`) uses `osb-mark-small.svg` as its favicon and as a 16 px mark before its name.

## Sizes and clear space

- **Minimum sizes:** the large mark from 40 px; below 40 px always use the small mark. The small mark from 16 px. Never show any mark below 16 px.
- **Clear space:** keep a quarter of the seal's width free on every side (33 in the 140 viewBox). The header ribbon is the one exception: it may overlap the bottom 2 units of the frame, as on osb.lol.
- **App icon grid (macOS):** the leather tile is the 824 px rounded square at the centre of the 1024 px canvas, with a soft shadow; the seal is 594 px wide on it. macOS 26 puts an icon that does not fill this shape on a grey plate; the tile does fill it.
- **Windows:** the seal alone, 924 px wide in the 1024 px art, with no plate. The `.ico` uses the small mark up to 32 px.

## Do not

- Do not bring back the eight-point star (two crossed squares) or use any hexagram, octagram, cross, crescent or swastika-like form, anywhere in the brand.
- Do not copy or imitate the Silkroad Online, Joymax or GAMEGAMI marks or any game art. Draw everything new.
- Do not move, mirror or remove the chipped corner, round the seal into a circle, or put the letters in another order.
- Do not recolour the seal (no blue, green or black seals) or change the gradient; do not outline the letters or add shadows or bevels to them.
- Do not stretch, skew or rotate the seal.
- Do not add text inside the seal, or put the ribbon on the app icon.
- Do not use the large mark below 40 px, or a scaled-down large mark in place of the small mark.
- Do not place the seal on a busy photo without its drop shadow or a leather plate behind it.
