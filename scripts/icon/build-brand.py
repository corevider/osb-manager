"""Writes the OSB seal mark and the OSB Manager icon masters into brand/.

The mark is a merchant's seal: a cinnabar stamp in a gold frame with one chipped corner, and carved
geometric letters, a round O over S and B. Every file in brand/ comes from this script, so change the
geometry or the colours here and run it again:

    python scripts/icon/build-brand.py [--site <osb-site folder>]

With --site it also writes the #emblem symbol into src/components/Sprite.astro and the small mark into
public/favicon.svg of the osb.lol site, keeping the line endings of the sprite file.

Files:
- osb-mark.svg: the mark for the osb.lol header and footer (viewBox -70 -70 140 140);
- osb-mark-small.svg: the 16 to 32 px mark on a 32 px grid, used as the favicon;
- osb-manager-icon.svg: the macOS master, the mark on the dark-leather tile in the 1024 px icon grid;
- osb-manager-icon-windows.svg: the Windows art for 40 to 256 px, the mark alone;
- osb-manager-icon-small.svg: the Windows art for 16 to 32 px, the same drawing as osb-mark-small.svg.
"""

import argparse
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRAND = ROOT / "brand"

HALF = 66
FRAME = 10
PAD = 9
STROKE = 9.5
CHIP = 0.16

GOLD = '<stop offset="0" stop-color="#fff0bf"/><stop offset="0.42" stop-color="#e2bb5c"/><stop offset="0.55" stop-color="#9a7228"/><stop offset="1" stop-color="#e9c66c"/>'
CINNABAR = '<stop offset="0" stop-color="#c24a32"/><stop offset="0.6" stop-color="#8a3020"/><stop offset="1" stop-color="#5d1f14"/>'
SHINE = '<stop offset="0" stop-color="#fff" stop-opacity="0.5"/><stop offset="1" stop-color="#fff" stop-opacity="0"/>'
INK = "#f2d57e"
OUTLINE = "#2a1d08"


def seal_defs(prefix: str) -> str:
    return (
        f'<linearGradient id="{prefix}gold" x1="0" y1="0" x2="0" y2="1">{GOLD}</linearGradient>'
        f'<linearGradient id="{prefix}cinnabar" x1="0" y1="0" x2="0" y2="1">{CINNABAR}</linearGradient>'
        f'<radialGradient id="{prefix}shine" cx="0.5" cy="0.2" r="0.5">{SHINE}</radialGradient>'
    )


def rect_path(x0: float, y0: float, x1: float, y1: float) -> str:
    return f"M{x0:g} {y0:g}H{x1:g}V{y1:g}H{x0:g}Z"


def letters(x0: float, y0: float, x1: float, y1: float, w: float) -> str:
    z = x1 - x0
    h = w / 2
    attrs = f'fill="none" stroke="{INK}" stroke-width="{w:g}" stroke-linejoin="round"'
    o_width, o_bottom = 0.66 * z, y0 + 0.47 * (y1 - y0)
    o_left = x0 + (z - o_width) / 2
    o_height = o_bottom - y0 - w
    letter_o = f'<rect x="{o_left + h:g}" y="{y0 + h:g}" width="{o_width - w:g}" height="{o_height:g}" rx="{o_height / 2:g}" {attrs}/>'
    lower = y0 + 0.57 * (y1 - y0)
    top, bottom, middle = lower + h, y1 - h, (lower + y1) / 2
    radius = (middle - top) / 2
    s_left, s_right = x0 + h, x0 + 0.44 * z - h
    letter_s = (
        f'<path d="M{s_right + h:g} {top:g}H{s_left + radius:g}A{radius:g} {radius:g} 0 0 0 {s_left:g} {top + radius:g}'
        f'A{radius:g} {radius:g} 0 0 0 {s_left + radius:g} {middle:g}H{s_right - radius:g}A{radius:g} {radius:g} 0 0 1 {s_right:g} {middle + radius:g}'
        f'A{radius:g} {radius:g} 0 0 1 {s_right - radius:g} {bottom:g}H{x0:g}" {attrs}/>'
    )
    b_left, b_right = x0 + 0.56 * z + h, x1 - h
    letter_b = (
        f'<path d="M{b_left:g} {top - h:g}V{bottom + h:g}M{b_left:g} {top:g}H{b_right - radius:g}A{radius:g} {radius:g} 0 0 1 {b_right - radius:g} {middle:g}H{b_left:g}'
        f'M{b_left:g} {middle:g}H{b_right - radius:g}A{radius:g} {radius:g} 0 0 1 {b_right - radius:g} {bottom:g}H{b_left:g}" {attrs}/>'
    )
    return letter_o + letter_s + letter_b


def seal(prefix: str) -> str:
    x0, y0, x1, y1 = -HALF, -HALF, HALF, HALF
    chip = HALF * CHIP
    outline = (
        f"M{x0 + 6:g} {y0:g}H{x1 - chip:g}L{x1:g} {y0 + chip:g}V{y1 - 6:g}Q{x1:g} {y1:g} {x1 - 6:g} {y1:g}"
        f"H{x0 + 6:g}Q{x0:g} {y1:g} {x0:g} {y1 - 6:g}V{y0 + 6:g}Q{x0:g} {y0:g} {x0 + 6:g} {y0:g}Z"
    )
    i0, i1 = x0 + FRAME, x1 - FRAME
    return (
        f'<path d="{outline}" fill="url(#{prefix}gold)" stroke="{OUTLINE}" stroke-width="2" stroke-linejoin="round"/>'
        f'<path d="{rect_path(i0, i0, i1, i1)}" fill="url(#{prefix}cinnabar)" stroke="{OUTLINE}" stroke-width="1.5"/>'
        f'<path d="{rect_path(i0 + 4, i0 + 4, i1 - 4, i1 - 4)}" fill="none" stroke="{INK}" stroke-width="1" opacity="0.45"/>'
        + letters(i0 + PAD, i0 + PAD, i1 - PAD, i1 - PAD, STROKE)
        + f'<ellipse cx="0" cy="{y0 + 22:g}" rx="{HALF * 0.7:g}" ry="{HALF * 0.18:g}" fill="url(#{prefix}shine)" opacity="0.35"/>'
    )


def small_seal() -> str:
    ink = "#ffe7a0"
    return (
        '<defs><linearGradient id="sgold" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffe9a8"/>'
        '<stop offset="0.5" stop-color="#e2bb5c"/><stop offset="1" stop-color="#c39437"/></linearGradient>'
        '<linearGradient id="sred" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#c24a32"/>'
        '<stop offset="1" stop-color="#8a3020"/></linearGradient></defs>'
        '<path d="M3 2H27L30 5V29H3Q2 29 2 28V3Q2 2 3 2Z" fill="url(#sgold)"/>'
        '<rect x="4" y="4" width="24" height="24" fill="url(#sred)"/>'
        f'<path d="M8 6H24V8H26V12H24V14H8V12H6V8H8Z M8 8V12H24V8Z" fill-rule="evenodd" fill="{ink}"/>'
        f'<path d="M8 16H14V18H8V20H12V22H14V24H12V26H6V24H12V22H8V20H6V18H8Z" fill="{ink}"/>'
        f'<path d="M18 16H24V18H26V20H24V22H26V24H24V26H18Z M20 18V20H24V18Z M20 22V24H24V22Z" fill-rule="evenodd" fill="{ink}"/>'
    )


def squircle(cx: float, cy: float, half: float, n: float = 5.0, steps: int = 256) -> str:
    points = []
    for index in range(steps):
        angle = 2 * math.pi * index / steps
        c, s = math.cos(angle), math.sin(angle)
        x = cx + half * math.copysign(abs(c) ** (2 / n), c)
        y = cy + half * math.copysign(abs(s) ** (2 / n), s)
        points.append(f"{x:.1f} {y:.1f}")
    return "M" + " L".join(points) + "Z"


APP_DEFS = (
    '<radialGradient id="leather" cx="0.5" cy="0.36" r="0.75"><stop offset="0" stop-color="#3a2a1b"/>'
    '<stop offset="0.6" stop-color="#1f160f"/><stop offset="1" stop-color="#100b07"/></radialGradient>'
    '<filter id="grain" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="3" seed="4" result="n"/>'
    '<feColorMatrix in="n" values="0 0 0 0 0.92  0 0 0 0 0.82  0 0 0 0 0.62  0 0 0 0.07 0"/><feComposite in2="SourceGraphic" operator="in"/></filter>'
    '<filter id="mottle" x="0" y="0" width="1" height="1"><feTurbulence type="fractalNoise" baseFrequency="0.012" numOctaves="4" seed="7" result="n"/>'
    '<feColorMatrix in="n" values="0 0 0 0 0.55  0 0 0 0 0.42  0 0 0 0 0.24  0 0 0 0.13 0"/><feComposite in2="SourceGraphic" operator="in"/></filter>'
    '<filter id="drop" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="16"/>'
    '<feComponentTransfer><feFuncA type="linear" slope="0.55"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
    '<filter id="tileShadow" x="-10%" y="-10%" width="120%" height="125%"><feGaussianBlur in="SourceAlpha" stdDeviation="10"/><feOffset dy="10"/>'
    '<feComponentTransfer><feFuncA type="linear" slope="0.32"/></feComponentTransfer><feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
)

MAC_TILE_HALF = 412
MAC_SEAL_SCALE = 4.5
WINDOWS_SEAL_SCALE = 7.0


def leather_tile() -> str:
    tile = squircle(512, 512, MAC_TILE_HALF)
    return (
        f'<path d="{tile}" fill="url(#leather)"/><path d="{tile}" fill="#000" filter="url(#mottle)"/><path d="{tile}" fill="#000" filter="url(#grain)"/>'
        f'<path d="{squircle(512, 512, MAC_TILE_HALF - 26)}" fill="none" stroke="#c9a24a" stroke-width="3" opacity="0.5"/>'
        f'<path d="{squircle(512, 512, MAC_TILE_HALF - 40)}" fill="none" stroke="#c9a24a" stroke-width="3" stroke-dasharray="14 12" stroke-linecap="round" opacity="0.3"/>'
        f'<path d="{tile}" fill="none" stroke="#000" stroke-opacity="0.5" stroke-width="3"/>'
    )


def svg(view: str, size: int, body: str) -> str:
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view}" width="{size}" height="{size}">{body}</svg>\n'


def placed_seal(scale: float) -> str:
    return f'<g filter="url(#drop)"><g transform="translate(512 512) scale({scale:g})">{seal("a-")}</g></g>'


def outputs() -> dict[str, str]:
    small = svg("0 0 32 32", 32, small_seal())
    return {
        "osb-mark.svg": svg("-70 -70 140 140", 140, f"<defs>{seal_defs('m-')}</defs>{seal('m-')}"),
        "osb-mark-small.svg": small,
        "osb-manager-icon.svg": svg(
            "0 0 1024 1024", 1024,
            f"<defs>{APP_DEFS}{seal_defs('a-')}</defs><g filter=\"url(#tileShadow)\">{leather_tile()}{placed_seal(MAC_SEAL_SCALE)}</g>",
        ),
        "osb-manager-icon-windows.svg": svg("0 0 1024 1024", 1024, f"<defs>{APP_DEFS}{seal_defs('a-')}</defs>{placed_seal(WINDOWS_SEAL_SCALE)}"),
        "osb-manager-icon-small.svg": small,
    }


def site_symbol() -> str:
    """The #emblem symbol for osb-site/src/components/Sprite.astro."""
    return f'<symbol id="emblem" viewBox="-70 -70 140 140"><defs>{seal_defs("m-")}</defs>{seal("m-")}</symbol>'


def update_site(site: Path, files: dict[str, str]) -> None:
    sprite = site / "src" / "components" / "Sprite.astro"
    raw = sprite.read_bytes().decode("utf-8")
    newline = "\r\n" if "\r\n" in raw else "\n"
    updated, count = re.subn(r'<symbol id="emblem".*?</symbol>', lambda _: site_symbol(), raw, count=1, flags=re.S)
    if count != 1:
        raise SystemExit(f"No #emblem symbol found in {sprite}.")
    sprite.write_bytes(updated.replace("\r\n", "\n").replace("\n", newline).encode("utf-8"))
    (site / "public" / "favicon.svg").write_text(files["osb-mark-small.svg"], encoding="utf-8", newline="\n")
    print(f"Updated #emblem in {sprite} and {site / 'public' / 'favicon.svg'}.")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site", type=Path)
    args = parser.parse_args()
    files = outputs()
    BRAND.mkdir(exist_ok=True)
    for name, content in files.items():
        (BRAND / name).write_text(content, encoding="utf-8", newline="\n")
    print(f"Wrote {', '.join(files)} to {BRAND}.")
    if args.site is not None:
        update_site(args.site, files)


if __name__ == "__main__":
    main()
