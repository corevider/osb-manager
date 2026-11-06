"""Renders the OSB share art from the seal: social previews, README headers, the site's og images and touch icon.

Usage:
    python scripts/brand/build-share-art.py [--site ../osb-site] [--bot ../osb] [--write-site]

Writes `docs/brand/` in this repository (OSB Manager). With `--bot`, also writes `docs/brand/` in the OSB bot
repository and copies `brand/osb-mark-small.svg` there (its build embeds it). With `--write-site`, also writes
`public/og-tr.jpg`, `public/og-en.jpg` and `public/apple-touch-icon.png` in osb-site. The fonts, the leather and the filigree corners come from osb-site, so `--site` (or its default,
the sibling folder) must point to an osb-site checkout. Edge renders the pages (see scripts/icon/edge_render.py).
"""

import argparse
import html
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "icon"))

from edge_render import screenshot  # noqa: E402

BRAND = ROOT / "brand"
SCALE = 2


@dataclass(frozen=True)
class Card:
    width: int
    height: int
    wordmark: str
    title: str
    lead: str
    footer: str
    lang: str = "en"


MANAGER = {
    "readme-header.jpg": Card(1280, 320, "OSB Manager", "OpenSRO accounts side by side",
                              "Each account in its own browser profile, with userscripts such as the OSB bot.",
                              "Open source · Windows and macOS · osb.lol"),
    "social-preview.jpg": Card(1280, 640, "OSB Manager", "OpenSRO accounts side by side",
                               "Each account in its own browser profile, with userscripts such as the OSB bot.",
                               "github.com/corevider/osb-manager · osb.lol"),
}

BOT = {
    "readme-header.jpg": Card(1280, 320, "OSB", "The open-source OpenSRO bot",
                              "Hunting, potions, pet loot and town trips in one compact panel.",
                              "Open source · GPL-2.0-or-later · osb.lol"),
    "social-preview.jpg": Card(1280, 640, "OSB", "The open-source OpenSRO bot",
                               "Hunting, potions, pet loot and town trips in one compact panel.",
                               "github.com/corevider/osb · osb.lol"),
}

SITE_OG = {
    "og-tr.jpg": Card(1200, 630, "OSB", "OpenSRO botu ve OSB Manager",
                      "OpenSRO için açık kaynak bot ve çoklu hesap uygulaması.", "osb.lol · Açık kaynak", "tr"),
    "og-en.jpg": Card(1200, 630, "OSB", "The OpenSRO bot and OSB Manager",
                      "An open-source bot for OpenSRO and a desktop app for running several accounts.",
                      "osb.lol · Open source"),
}


def font_faces(site: Path) -> str:
    fonts = site / "public" / "fonts"
    faces = [("Cinzel", 900, "cinzel-tr-900-normal"), ("Alegreya", 700, "alegreya-tr-700-normal"),
             ("Barlow", 400, "barlow-tr-400-normal"), ("Barlow Condensed", 700, "barlow-condensed-tr-700-normal")]
    rules = []
    for family, weight, name in faces:
        path = fonts / f"{name}.woff2"
        if not path.exists():
            raise SystemExit(f"Font {path} is missing. Point --site to an osb-site checkout.")
        rules.append(f"@font-face{{font-family:'{family}';font-weight:{weight};src:url('{path.as_uri()}') format('woff2')}}")
    return "".join(rules)


def seal_svg() -> str:
    return (BRAND / "osb-mark.svg").read_text(encoding="utf-8").replace('width="140" height="140"', 'class="seal"')


def card_page(card: Card, site: Path) -> str:
    orn = site / "src" / "assets" / "orn"
    tall = card.height >= 600
    seal = round(card.height * (0.56 if tall else 0.74))
    corner = 112 if tall else 80
    word = 132 if card.wordmark == "OSB" else 76
    if not tall:
        word = round(word * 0.72)
    title = 40 if tall else 30
    lead = 25 if tall else 19
    return f"""<!doctype html><html lang="{card.lang}"><head><meta charset="utf-8"><style>
{font_faces(site)}
*{{box-sizing:border-box}}
html,body{{margin:0;width:{card.width}px;height:{card.height}px;overflow:hidden;background:#120e0b}}
.card{{position:relative;width:100%;height:100%;display:flex;align-items:center;gap:{round(card.height * 0.1)}px;
padding:0 {round(card.width * 0.07)}px;
background:radial-gradient(70% 90% at 22% 50%,rgba(150,70,30,.22),transparent 70%),
radial-gradient(120% 90% at 50% 120%,rgba(0,0,0,.55),transparent 70%),
url('{(orn / "leather.jpg").as_uri()}') center/512px 512px #120e0b}}
.card::before{{content:"";position:absolute;inset:10px;border:1px solid rgba(201,162,74,.5);
box-shadow:0 0 0 1px rgba(0,0,0,.7),inset 0 0 0 1px rgba(0,0,0,.6);pointer-events:none}}
.corner{{position:absolute;top:7px;width:{corner}px;height:{corner}px;
filter:drop-shadow(0 2px 2px rgba(0,0,0,.7))}}
.corner.l{{left:7px}}.corner.r{{right:7px}}
.seal{{flex:none;width:{seal}px;height:{seal}px;filter:drop-shadow(0 10px 18px rgba(0,0,0,.65))}}
.text{{min-width:0}}
.word{{margin:0;font:900 {word}px/1 'Cinzel',serif;letter-spacing:.04em;
background:linear-gradient(180deg,#fff0bf,#e2bb5c 46%,#9a7228 60%,#e9c66c);-webkit-background-clip:text;background-clip:text;
color:transparent;filter:drop-shadow(0 3px 0 rgba(0,0,0,.75))}}
.title{{margin:{round(title * 0.35)}px 0 0;text-wrap:balance;font:700 {title}px/1.15 'Alegreya',serif;color:#f3e5c6}}
.lead{{margin:{round(lead * 0.45)}px 0 0;max-width:30em;font:400 {lead}px/1.35 'Barlow',sans-serif;color:#d8c8a6}}
.foot{{margin:{round(lead * 0.9)}px 0 0;font:700 {round(lead * 0.82)}px/1 'Barlow Condensed',sans-serif;
letter-spacing:.14em;text-transform:uppercase;color:#c9a24a}}
</style></head><body><div class="card">
<img class="corner l" src="{(orn / 'corner-l-2x.png').as_uri()}" alt="">
<img class="corner r" src="{(orn / 'corner-r-2x.png').as_uri()}" alt="">
{seal_svg()}
<div class="text"><p class="word">{html.escape(card.wordmark)}</p><p class="title">{html.escape(card.title)}</p>
<p class="lead">{html.escape(card.lead)}</p><p class="foot">{html.escape(card.footer)}</p></div>
</div></body></html>"""


def touch_icon_page(site: Path) -> str:
    orn = site / "src" / "assets" / "orn"
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
html,body{{margin:0;width:180px;height:180px;overflow:hidden}}
body{{display:grid;place-items:center;background:radial-gradient(80% 80% at 50% 35%,rgba(150,90,40,.35),transparent 70%),
url('{(orn / "leather.jpg").as_uri()}') center/360px 360px #1a140f}}
.seal{{width:132px;height:132px;filter:drop-shadow(0 4px 6px rgba(0,0,0,.6))}}
</style></head><body>{seal_svg()}</body></html>"""


def render(page: str, width: int, height: int, scale: int) -> Image.Image:
    with tempfile.TemporaryDirectory(prefix="osb-share-") as work:
        path = Path(work) / "page.html"
        path.write_text(page, encoding="utf-8")
        return screenshot(path, width, height, scale)


def write_cards(cards: dict[str, Card], site: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    for name, card in cards.items():
        image = render(card_page(card, site), card.width, card.height, SCALE).convert("RGB")
        if card.height >= 600:
            image = image.resize((card.width, card.height), Image.Resampling.LANCZOS)
        image.save(target / name, quality=86, optimize=True, progressive=True)
        print(f"Wrote {target / name} ({image.width}x{image.height}, {(target / name).stat().st_size} bytes).")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--site", type=Path, default=ROOT.parent / "osb-site")
    parser.add_argument("--bot", type=Path)
    parser.add_argument("--write-site", action="store_true", help="also write the og images and touch icon into --site")
    args = parser.parse_args()
    site = args.site.resolve()
    write_cards(MANAGER, site, ROOT / "docs" / "brand")
    if args.bot is not None:
        bot_brand = args.bot.resolve() / "docs" / "brand"
        write_cards(BOT, site, bot_brand)
        (bot_brand / "osb-mark-small.svg").write_bytes((BRAND / "osb-mark-small.svg").read_bytes())
        print(f"Copied osb-mark-small.svg to {bot_brand}.")
    if args.write_site:
        write_cards(SITE_OG, site, site / "public")
        icon = render(touch_icon_page(site), 180, 180, 1).convert("RGB")
        icon.save(site / "public" / "apple-touch-icon.png", optimize=True)
        print(f"Wrote {site / 'public' / 'apple-touch-icon.png'}.")


if __name__ == "__main__":
    main()
