"""Shows a candidate OSB mark in the real osb.lol pages before the site changes.

The script copies the built site (osb-site/dist), swaps the #emblem symbol in every page and the favicon for
the candidate, serves the copy on 127.0.0.1 and takes Edge screenshots of the header at 1440 and 390 px and
of the footer (the privacy page, which is short enough to fit). Build the site first with `npm run build` in osb-site.

Usage: python scripts/icon/site-preview.py <symbol.txt> <favicon.svg> <out prefix> [--site <osb-site folder>]
"""

import argparse
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from edge_render import screenshot

ROOT = Path(__file__).resolve().parents[2]
FOOTER_PAGE_HEIGHT = 3200
FOOTER_HEIGHT = 470
EMBLEM = re.compile(r'<symbol id="emblem".*?</symbol>', re.S)


def free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def prepare(dist: Path, work: Path, symbol: str, favicon: Path) -> int:
    shutil.copytree(dist, work, dirs_exist_ok=True)
    pages = 0
    for page in work.rglob("*.html"):
        source = page.read_text(encoding="utf-8")
        swapped, count = EMBLEM.subn(lambda _: symbol, source, count=1)
        if count:
            page.write_text(swapped, encoding="utf-8")
            pages += 1
    shutil.copyfile(favicon, work / "favicon.svg")
    return pages


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("symbol", type=Path)
    parser.add_argument("favicon", type=Path)
    parser.add_argument("out")
    parser.add_argument("--site", type=Path, default=ROOT.parent / "osb-site")
    args = parser.parse_args()
    dist = args.site / "dist"
    if not (dist / "index.html").exists():
        raise SystemExit(f"{dist} has no build. Run npm run build in {args.site} first.")
    symbol = args.symbol.read_text(encoding="utf-8").strip()
    with tempfile.TemporaryDirectory(prefix="osb-site-") as work_dir:
        work = Path(work_dir) / "site"
        pages = prepare(dist, work, symbol, args.favicon)
        port = free_port()
        server = subprocess.Popen(
            [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", str(work)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            time.sleep(1.0)
            base = f"http://127.0.0.1:{port}"
            screenshot(f"{base}/", 1440, 420).convert("RGB").save(f"{args.out}-header-1440.png")
            screenshot(f"{base}/", 390, 300).convert("RGB").save(f"{args.out}-header-390.png")
            page = screenshot(f"{base}/gizlilik/", 1440, FOOTER_PAGE_HEIGHT).convert("RGB")
            page.crop((0, FOOTER_PAGE_HEIGHT - FOOTER_HEIGHT, 1440, FOOTER_PAGE_HEIGHT)).save(f"{args.out}-footer-1440.png")
        finally:
            server.terminate()
            server.wait(timeout=10)
    print(f"Swapped the emblem in {pages} pages; wrote {args.out}-header-1440.png, -header-390.png, -footer-1440.png.")


main()
