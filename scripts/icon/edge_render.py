"""Renders SVG and HTML files to PNG with the installed Microsoft Edge in headless mode.

Each call starts its own Edge with a throwaway profile, so an Edge the user has open is never touched.
"""

import os
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

EDGE = Path(os.environ.get("EDGE_PATH", r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"))
MIN_WINDOW = 256


def screenshot(page: Path | str, width: int, height: int, scale: float = 1.0) -> Image.Image:
    if not EDGE.exists():
        raise SystemExit(f"Microsoft Edge was not found at {EDGE}. Set EDGE_PATH to msedge.exe.")
    with tempfile.TemporaryDirectory(prefix="osb-icon-") as work:
        target = Path(work) / "shot.png"
        command = [
            str(EDGE),
            "--headless=new",
            "--disable-gpu",
            "--no-first-run",
            "--no-default-browser-check",
            "--hide-scrollbars",
            "--allow-file-access-from-files",
            f"--user-data-dir={Path(work) / 'profile'}",
            "--default-background-color=00000000",
            f"--force-device-scale-factor={scale}",
            f"--window-size={max(width, MIN_WINDOW)},{max(height, MIN_WINDOW)}",
            f"--screenshot={target}",
            page if isinstance(page, str) else page.resolve().as_uri(),
        ]
        subprocess.run(command, capture_output=True, timeout=120, check=False)
        if not target.exists():
            raise SystemExit(f"Edge did not write a screenshot of {page}.")
        image = Image.open(target).convert("RGBA")
        image.load()
    return image.crop((0, 0, round(width * scale), round(height * scale)))


def render_svg(svg: Path, size: int) -> Image.Image:
    with tempfile.TemporaryDirectory(prefix="osb-icon-page-") as work:
        page = Path(work) / "page.html"
        page.write_text(
            "<!doctype html><html><head><style>html,body{margin:0;background:transparent}"
            f"img{{display:block;width:{size}px;height:{size}px}}</style></head>"
            f"<body><img src=\"{svg.resolve().as_uri()}\"></body></html>",
            encoding="utf-8",
        )
        return screenshot(page, size, size)
