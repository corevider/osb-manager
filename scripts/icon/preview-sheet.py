"""Builds a preview sheet of one OSB Manager icon design.

The sheet shows the mark on the site (header at 1440 and 390 px, footer, favicon in a browser tab), the
macOS master at 1024 px, every Windows size on a light and a dark background, the 16, 24 and 32 px renders
enlarged without smoothing, a Windows 11 title bar and taskbar, a macOS Dock and the icon next to the
header emblem. Edge renders every size from the SVG, then renders the sheet. The site screenshots come from
site-preview.py; --symbol puts the candidate #emblem into the sheet's copy of the site sprite.

Usage: python scripts/icon/preview-sheet.py <mac.svg> <windows.svg> <small.svg> <title> <note> <out.png>
       [--site <osb-site folder>] [--old <old icon png>] [--symbol <symbol.txt>] [--shots <prefix>]
"""

import argparse
import html
import re
import tempfile
from pathlib import Path

from edge_render import render_svg, screenshot

ROOT = Path(__file__).resolve().parents[2]
SIZES = [256, 64, 48, 32, 24, 16]
SMALL_LIMIT = 32
WIDTH, HEIGHT = 2200, 3560


def site_sprite(site: Path, symbol: str | None) -> str:
    source = (site / "src" / "components" / "Sprite.astro").read_text(encoding="utf-8")
    match = re.search(r"<svg class=\"sprite\".*?</svg>", source, re.S)
    if match is None:
        raise SystemExit("The sprite was not found in Sprite.astro.")
    sprite = match.group(0)
    if symbol is not None:
        sprite = re.sub(r'<symbol id="emblem".*?</symbol>', lambda _: symbol, sprite, count=1, flags=re.S)
    return sprite.replace('class="sprite"', 'class="sprite" style="position:absolute;width:0;height:0"')


def renders(mac: Path, windows: Path, small: Path, work: Path) -> dict[str, str]:
    files = {}
    jobs = [("mac-1024", mac, 1024), ("mac-64", mac, 64)]
    jobs += [(f"win-{size}", small if size <= SMALL_LIMIT else windows, size) for size in SIZES + [128]]
    for name, svg, size in jobs:
        target = work / f"{name}.png"
        render_svg(svg, size).save(target)
        files[name] = target.as_uri()
    return files


def placeholder(size: int, tone: str, radius: str) -> str:
    return f'<span class="ph" style="width:{size}px;height:{size}px;background:{tone};border-radius:{radius}"></span>'


def site_section(shots: str | None, files: dict[str, str]) -> str:
    if shots is None:
        return ""
    uri = lambda suffix: Path(f"{shots}-{suffix}.png").resolve().as_uri()
    tab = lambda theme, size, scale: (
        f'<div class="tabs {theme}" style="zoom:{scale}"><span class="tab"><img src="{files[f"win-{size}"]}" width="16" height="16">'
        '<span>OSB &middot; OpenSRO bot</span><span class="x">&#10005;</span></span><span class="tab idle">New tab</span></div>'
    )
    return f"""<h2>On osb.lol: header at 1440 and 390 px (real pages, candidate swapped in)</h2>
<div class="row"><img src="{uri('header-1440')}" width="1440" height="240" style="object-fit:cover;object-position:top"><img src="{uri('header-390')}" width="390" height="300"></div>
<h2>Footer mark and favicon (browser tab at 100 % with the 16 px render, at 200 % with the 32 px render)</h2>
<div class="row"><img src="{uri('footer-1440')}" width="1100" height="300" style="object-fit:cover;object-position:left top">
<div style="display:flex;flex-direction:column;gap:14px">{tab('tl', 16, 1)}{tab('td', 16, 1)}{tab('tl', 32, 2)}</div></div>"""


def page(title: str, note: str, files: dict[str, str], site: Path, old: Path | None, symbol: str | None, shots: str | None) -> str:
    fonts = (site / "public" / "fonts").resolve().as_uri()
    sizes_row = "".join(
        f'<figure><img src="{files[f"win-{size}"]}" width="{size}" height="{size}"><figcaption>{size}</figcaption></figure>'
        for size in SIZES
    )
    zoom = "".join(
        f'<figure><img class="px" src="{files[f"win-{size}"]}" width="{size * scale}" height="{size * scale}">'
        f"<figcaption>{size} px, {scale}x</figcaption></figure>"
        for size, scale in ((32, 6), (24, 8), (16, 12))
    )
    taskbar_icons = (
        placeholder(24, "#5b6b7d", "5px") + placeholder(24, "#7d6b5b", "12px")
        + f'<span class="tb-app"><img src="{files["win-24"]}" width="24" height="24"></span>'
        + placeholder(24, "#5b7d6b", "5px")
    )
    dock_icons = (
        placeholder(64, "linear-gradient(#9aa7b4,#6c7884)", "15px")
        + placeholder(64, "linear-gradient(#b4a89a,#847a6c)", "15px")
        + f'<span class="dock-app"><img src="{files["mac-64"]}" width="64" height="64"></span>'
        + placeholder(64, "linear-gradient(#9ab4a5,#6c8478)", "15px")
    )
    old_html = ""
    if old is not None:
        old_html = f'<figure><img src="{old.resolve().as_uri()}" width="128" height="128"><figcaption>old icon</figcaption></figure>'
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face{{font-family:Cinzel;font-weight:700;src:url("{fonts}/cinzel-tr-700-normal.woff2") format("woff2")}}
@font-face{{font-family:Cinzel;font-weight:900;src:url("{fonts}/cinzel-tr-900-normal.woff2") format("woff2")}}
*{{box-sizing:border-box}}
html,body{{margin:0;width:{WIDTH}px;height:{HEIGHT}px;background:#d9d4cb;font:15px/1.4 "Segoe UI",system-ui,sans-serif;color:#222}}
header{{padding:28px 40px 8px}} h1{{margin:0;font:700 34px/1.2 Cinzel,serif;color:#2a1d08}} header p{{margin:6px 0 0;max-width:1700px;font-size:17px}}
.row{{display:flex;gap:24px;padding:16px 40px}}
.panel{{flex:1;border-radius:10px;padding:20px;display:flex;align-items:center;gap:28px;flex-wrap:wrap}}
.light{{background:#f3f3f3}} .dark{{background:#1f1f1f;color:#ddd}}
figure{{margin:0;display:flex;flex-direction:column;align-items:center;gap:8px}} figcaption{{font-size:13px;opacity:.75}}
img{{display:block}} .px{{image-rendering:pixelated}}
h2{{margin:0;padding:12px 40px 0;font:600 18px/1.3 "Segoe UI",sans-serif}}
.titlebar{{height:32px;display:flex;align-items:center;gap:10px;padding:0 0 0 10px;font:12px "Segoe UI";border-radius:8px 8px 0 0}}
.titlebar .sp{{flex:1}} .titlebar .cap{{width:46px;height:32px;display:flex;align-items:center;justify-content:center;font-size:14px}}
.window{{width:520px;border-radius:8px;box-shadow:0 8px 24px rgba(0,0,0,.25);overflow:hidden}}
.window .body{{height:90px}}
.w-light .titlebar{{background:#f3f3f3;color:#1a1a1a}} .w-light .body{{background:#fbfbfb}}
.w-dark .titlebar{{background:#202020;color:#fff}} .w-dark .body{{background:#2b2b2b}}
.taskbar{{width:520px;height:48px;display:flex;align-items:center;justify-content:center;gap:14px;border-radius:0 0 8px 8px}}
.t-light{{background:#eef1f5}} .t-dark{{background:#1c1c1c}}
.ph{{display:inline-block}}
.tb-app{{position:relative;padding:8px;border-radius:5px}} .t-light .tb-app{{background:rgba(0,0,0,.06)}} .t-dark .tb-app{{background:rgba(255,255,255,.08)}}
.tb-app::after{{content:"";position:absolute;left:50%;bottom:1px;width:16px;height:3px;margin-left:-8px;border-radius:2px;background:#4cc2ff}}
.desk{{display:flex;flex-direction:column;align-items:center;padding:24px;border-radius:10px}}
.desk-light{{background:linear-gradient(160deg,#c7d6e6,#e8e0d0)}} .desk-dark{{background:linear-gradient(160deg,#20324a,#2b2420)}}
.dock{{display:flex;gap:10px;align-items:flex-end;padding:9px 12px;border-radius:24px;background:rgba(255,255,255,.28);border:1px solid rgba(255,255,255,.45);backdrop-filter:blur(20px)}}
.d-dark .dock{{background:rgba(30,30,30,.42);border-color:rgba(255,255,255,.18)}}
.dock-app{{position:relative}} .dock-app::after{{content:"";position:absolute;left:50%;bottom:-6px;width:4px;height:4px;margin-left:-2px;border-radius:50%;background:rgba(0,0,0,.6)}}
.d-dark .dock-app::after{{background:rgba(255,255,255,.75)}}
.mac-desk{{width:520px;height:190px;justify-content:flex-end;padding-bottom:16px}}
.site{{background:#0c0a08;border-radius:10px;padding:26px 40px;display:flex;align-items:center;gap:56px;color:#ecdfc3}}
.site .emblem{{width:150px;height:150px}}
.tabs{{display:flex;gap:2px;padding:6px 8px 0;width:420px;font:12px 'Segoe UI'}} .tabs .tab{{display:flex;align-items:center;gap:8px;padding:8px 10px;width:230px;border-radius:8px 8px 0 0}} .tabs .x{{margin-left:auto;font-size:10px;opacity:.6}} .tabs .idle{{background:transparent!important;opacity:.6}}
.tl{{background:#e3e3e3;color:#1a1a1a}} .tl .tab{{background:#fff}} .td{{background:#1c1c1c;color:#eee}} .td .tab{{background:#2f2f2f}} .site .lbl{{font:700 14px/1.2 Cinzel,serif;letter-spacing:.12em;color:#f2d57e}}
</style></head><body>
{site_sprite(site, symbol)}
<header><h1>{html.escape(title)}</h1><p>{html.escape(note)}</p></header>
{site_section(shots, files)}
<h2>macOS master, 1024 px</h2>
<div class="row"><div class="panel light" style="justify-content:center"><img src="{files['mac-1024']}" width="1024" height="1024"></div>
<div class="panel dark" style="justify-content:center"><img src="{files['mac-1024']}" width="1024" height="1024"></div></div>
<h2>Windows sizes (16 to 32 px from the small variant)</h2>
<div class="row"><div class="panel light">{sizes_row}</div><div class="panel dark">{sizes_row}</div></div>
<div class="row"><div class="panel light">{zoom}</div><div class="panel dark">{zoom}</div></div>
<h2>Windows 11 title bar and taskbar, macOS Dock</h2>
<div class="row">
<div class="panel light" style="flex-direction:column;align-items:flex-start;gap:16px">
<div class="window w-light"><div class="titlebar"><img src="{files['win-16']}" width="16" height="16"><span>OSB Manager</span><span class="sp"></span><span class="cap">&#8212;</span><span class="cap">&#9744;</span><span class="cap">&#10005;</span></div><div class="body"></div><div class="taskbar t-light">{taskbar_icons}</div></div>
<div class="desk desk-light mac-desk"><div class="dock">{dock_icons}</div></div></div>
<div class="panel dark" style="flex-direction:column;align-items:flex-start;gap:16px">
<div class="window w-dark"><div class="titlebar"><img src="{files['win-16']}" width="16" height="16"><span>OSB Manager</span><span class="sp"></span><span class="cap">&#8212;</span><span class="cap">&#9744;</span><span class="cap">&#10005;</span></div><div class="body"></div><div class="taskbar t-dark">{taskbar_icons}</div></div>
<div class="desk desk-dark mac-desk d-dark"><div class="dock">{dock_icons}</div></div></div>
</div>
<h2>Next to the osb.lol header emblem</h2>
<div class="row"><div class="site">
<svg class="emblem" viewBox="-100 -100 200 200"><use href="#emblem" x="-70" y="-84" width="140" height="140"/><use href="#ribbon" x="-100" y="-100" width="200" height="200"/><use href="#ribbon-tr" x="-100" y="-100" width="200" height="200"/></svg>
<figure><img src="{files['win-128']}" width="128" height="128"><figcaption class="lbl">Windows 128</figcaption></figure>
<figure><img src="{files['win-48']}" width="48" height="48"><figcaption class="lbl">48</figcaption></figure>
<figure><img src="{files['win-32']}" width="32" height="32"><figcaption class="lbl">32</figcaption></figure>
<figure><img src="{files['win-16']}" width="16" height="16"><figcaption class="lbl">16</figcaption></figure>
<figure><img src="{files['win-32']}" width="32" height="32"><figcaption class="lbl">favicon</figcaption></figure>
</div>{old_html}</div>
</body></html>"""


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mac", type=Path)
    parser.add_argument("windows", type=Path)
    parser.add_argument("small", type=Path)
    parser.add_argument("title")
    parser.add_argument("note")
    parser.add_argument("out", type=Path)
    parser.add_argument("--site", type=Path, default=ROOT.parent / "osb-site")
    parser.add_argument("--old", type=Path)
    parser.add_argument("--symbol", type=Path)
    parser.add_argument("--shots")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="osb-sheet-") as work_dir:
        work = Path(work_dir)
        files = renders(args.mac, args.windows, args.small, work)
        sheet = work / "sheet.html"
        sheet.write_text(page(args.title, args.note, files, args.site, args.old, args.symbol.read_text(encoding="utf-8").strip() if args.symbol else None, args.shots), encoding="utf-8")
        screenshot(sheet, WIDTH, HEIGHT).convert("RGB").save(args.out, quality=90)
    print(f"Wrote {args.out}.")


main()
