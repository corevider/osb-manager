"""Prints the outline of a word in a WOFF2 font as one SVG path, so the icon carries no live text.

fontTools reads the font. WOFF2 needs a Brotli decoder; when the Python brotli module is missing, the
script uses the one built into Node.js. The path is in font units with the y axis flipped, the baseline
at y = 0 and the word centred on x = 0.

Usage: python scripts/icon/text-to-path.py <font.woff2> <word> [letter-spacing in em]
"""

import subprocess
import sys
import types

try:
    import brotli
except ImportError:
    def node_decompress(data: bytes) -> bytes:
        script = "process.stdout.write(require('zlib').brotliDecompressSync(require('fs').readFileSync(0)))"
        return subprocess.run(["node", "-e", script], input=data, capture_output=True, check=True).stdout

    sys.modules["brotli"] = types.SimpleNamespace(decompress=node_decompress)

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont


def word_path(font_path: str, word: str, spacing_em: float) -> tuple[str, int]:
    font = TTFont(font_path)
    glyphs = font.getGlyphSet()
    cmap = font.getBestCmap()
    units = font["head"].unitsPerEm
    names = [cmap[ord(char)] for char in word]
    advances = [font["hmtx"][name][0] for name in names]
    spacing = spacing_em * units
    width = sum(advances) + spacing * (len(names) - 1)
    pen = SVGPathPen(glyphs, ntos=lambda value: f"{value:.1f}".rstrip("0").rstrip("."))
    cursor = -width / 2
    for name, advance in zip(names, advances):
        glyphs[name].draw(TransformPen(pen, (1, 0, 0, -1, cursor, 0)))
        cursor += advance + spacing
    return pen.getCommands(), units


def main() -> None:
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    spacing = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    path, units = word_path(sys.argv[1], sys.argv[2], spacing)
    print(f"<!-- unitsPerEm {units} -->")
    print(path)


if __name__ == "__main__":
    main()
