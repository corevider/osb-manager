"""Builds the OSB Manager icons from the SVG masters in brand/.

- src/OsbManager/app.ico: 16, 20, 24, 32, 40, 48, 64, 128 and 256 px PNG entries. Up to 32 px the entries come
  from brand/osb-manager-icon-small.svg (the pixel-grid seal), above that from brand/osb-manager-icon-windows.svg.
- docs/macos/app-icon-1024.png: the macOS master from brand/osb-manager-icon.svg. macos/scripts/build-app.sh
  makes AppIcon.icns from it with sips and iconutil.

The installed Microsoft Edge renders each size in headless mode (scripts/icon/edge_render.py); Pillow writes
the files. Run python scripts/icon/build-brand.py first when the art changed.

Usage: python scripts/make-icon.py
"""

import struct
import sys
from io import BytesIO
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts" / "icon"))

from edge_render import render_svg

BRAND = ROOT / "brand"
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
SMALL_LIMIT = 32
MAC_SIZE = 1024


def png_bytes(image: Image.Image) -> bytes:
    buffer = BytesIO()
    image.save(buffer, format="PNG", optimize=True)
    return buffer.getvalue()


def write_ico(images: list[tuple[int, bytes]], target: Path) -> None:
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries = b""
    for size, data in images:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    target.write_bytes(header + entries + b"".join(data for _, data in images))


def windows_art(size: int) -> Image.Image:
    name = "osb-manager-icon-small.svg" if size <= SMALL_LIMIT else "osb-manager-icon-windows.svg"
    return render_svg(BRAND / name, size)


def main() -> None:
    ico = ROOT / "src" / "OsbManager" / "app.ico"
    write_ico([(size, png_bytes(windows_art(size))) for size in SIZES], ico)
    print(f"Wrote {ico} with sizes {', '.join(str(size) for size in SIZES)}.")
    mac = ROOT / "docs" / "macos" / "app-icon-1024.png"
    render_svg(BRAND / "osb-manager-icon.svg", MAC_SIZE).save(mac, optimize=True)
    print(f"Wrote {mac}.")


main()
