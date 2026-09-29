#!/usr/bin/env python3
"""Generates Yap's Phosphor icons (https://phosphoricons.com, MIT) as custom SF Symbols, and the table that maps
SF Symbol names to them.

  scripts/phosphor-symbols.py <swiftdraw>

<swiftdraw> is SwiftDraw's command-line tool (github.com/swhitty/SwiftDraw: `swift build -c release`, then
.build/release/swiftdrawcli). Writes VoiceInk/Assets.xcassets/Phosphor/*.symbolset and
VoiceInk/DesignSystem/Theme/PhosphorIcons.generated.swift. `Image(yapIcon:)` looks names up in that table and falls
back to the SF Symbol, so an icon switches to Phosphor by adding a row to ICONS and rerunning this script.

Phosphor's regular weight fills every weight of the symbol: its thin and bold weights have different path
structure, which SF Symbols can't interpolate. "fill" rows use Phosphor's fill style. "duo" rows also get
`<name>.duo`, the duotone's tint layer on the same alignment as the outline, for selected sidebar items.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

PHOSPHOR = "2.1.1"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "VoiceInk/Assets.xcassets/Phosphor")
SWIFT_OUT = os.path.join(ROOT, "VoiceInk/DesignSystem/Theme/PhosphorIcons.generated.swift")

# SF Symbol name → (Phosphor name, style). style: "regular", "fill" or "duo" (regular + duotone tint layer).
ICONS = {
    # Sidebar
    "house": ("house", "duo"),
    "square.stack": ("stack", "duo"),
    "character.book.closed": ("book-open-text", "duo"),
    "cpu": ("cpu", "duo"),
    "mic": ("microphone", "duo"),
    "gearshape": ("gear-six", "duo"),
    "clock": ("clock", "duo"),
    "person.crop.circle": ("user-circle", "duo"),
    "waveform": ("waveform", "duo"),
    # Most used elsewhere
    "xmark": ("x", "regular"),
    "globe": ("globe", "regular"),
    "sparkles": ("sparkle", "regular"),
    "checkmark": ("check", "regular"),
    "checkmark.circle": ("check-circle", "regular"),
    "checkmark.circle.fill": ("check-circle", "fill"),
    "xmark.circle": ("x-circle", "regular"),
    "xmark.circle.fill": ("x-circle", "fill"),
    "exclamationmark.triangle": ("warning", "regular"),
    "exclamationmark.triangle.fill": ("warning", "fill"),
    "info.circle": ("info", "regular"),
    "arrow.right": ("arrow-right", "regular"),
    "arrow.up.right": ("arrow-up-right", "regular"),
    "arrow.clockwise": ("arrow-clockwise", "regular"),
    "arrow.counterclockwise": ("arrow-counter-clockwise", "regular"),
    "trash": ("trash", "regular"),
    "folder": ("folder", "regular"),
    "ellipsis.circle": ("dots-three-circle", "regular"),
    "plus.circle.fill": ("plus-circle", "fill"),
    "pencil": ("pencil-simple", "regular"),
    "pencil.circle.fill": ("pencil-circle", "fill"),
    "square.and.pencil": ("note-pencil", "regular"),
    "chevron.right": ("caret-right", "regular"),
    "chevron.left": ("caret-left", "regular"),
    "chevron.down": ("caret-down", "regular"),
    "chevron.up.chevron.down": ("caret-up-down", "regular"),
    "magnifyingglass": ("magnifying-glass", "regular"),
    "mic.fill": ("microphone", "fill"),
    "gearshape.fill": ("gear-six", "fill"),
    "internaldrive": ("hard-drive", "regular"),
    "chart.bar.xaxis": ("chart-bar", "regular"),
    "wand.and.stars": ("magic-wand", "regular"),
    "square.grid.2x2": ("squares-four", "regular"),
    "play.fill": ("play", "fill"),
}


def fetch(weight, name, cache):
    suffix = "" if weight == "regular" else f"-{weight}"
    path = os.path.join(cache, f"{name}{suffix}.svg")
    if not os.path.exists(path):
        url = f"https://cdn.jsdelivr.net/npm/@phosphor-icons/core@{PHOSPHOR}/assets/{weight}/{name}{suffix}.svg"
        with urllib.request.urlopen(url) as response, open(path, "wb") as out:
            out.write(response.read())
    return path


def swiftdraw(tool, svg, extra):
    out = subprocess.run([tool, svg, "--format", "sfsymbol", *extra], capture_output=True, text=True, check=True)
    insets = re.search(r"Alignment: --insets (\S+)", out.stdout).group(1)
    return svg[:-4] + "-symbol.svg", insets


def symbolset(asset, symbol_svg):
    folder = os.path.join(ASSETS, f"{asset}.symbolset")
    os.makedirs(folder)
    shutil.copy(symbol_svg, os.path.join(folder, f"{asset}.svg"))
    contents = {"info": {"author": "xcode", "version": 1}, "symbols": [{"filename": f"{asset}.svg", "idiom": "universal"}]}
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")


def tint_layer(duotone_svg, out_svg):
    """The duotone's opacity="0.2" shapes alone, at full opacity: the part a selected item fills with color."""
    text = open(duotone_svg, encoding="utf-8").read()
    layer = re.findall(r"<[^>]*opacity=\"0\.2\"[^>]*/>", text)
    assert layer, duotone_svg
    head = re.match(r"<svg[^>]*>", text).group(0)
    body = "".join(re.sub(r'\sopacity="0\.2"', "", shape) for shape in layer)
    open(out_svg, "w", encoding="utf-8").write(f"{head}{body}</svg>")


def main():
    tool = sys.argv[1]
    cache = tempfile.mkdtemp(prefix="phosphor-")
    if os.path.exists(ASSETS):
        shutil.rmtree(ASSETS)
    os.makedirs(ASSETS)
    with open(os.path.join(ASSETS, "Contents.json"), "w") as f:
        f.write('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')

    rows, made = [], set()
    for sf, (name, style) in ICONS.items():
        asset = f"ph.{name}" + (".fill" if style == "fill" else "")
        if asset not in made:
            if style == "fill":
                symbol, _ = swiftdraw(tool, fetch("fill", name, cache), [])
            else:
                symbol, insets = swiftdraw(tool, fetch("regular", name, cache), [])
            symbolset(asset, symbol)
            made.add(asset)
            if style == "duo":
                tint = os.path.join(cache, f"{name}-tint.svg")
                tint_layer(fetch("duotone", name, cache), tint)
                # The outline's insets, so the tint lines up with it exactly.
                symbol, _ = swiftdraw(tool, tint, ["--insets", insets])
                symbolset(f"ph.{name}.duo", symbol)
        rows.append(f'        "{sf}": "{asset}",')

    with open(SWIFT_OUT, "w") as f:
        f.write("// Generated by scripts/phosphor-symbols.py from its ICONS table. Do not edit.\n\n")
        f.write("enum PhosphorIcons {\n")
        f.write("    /// SF Symbol name → Phosphor custom symbol in Assets.xcassets/Phosphor.\n")
        f.write("    static let bySystemName: [String: String] = [\n")
        f.write("\n".join(rows) + "\n    ]\n}\n")
    shutil.rmtree(cache)
    print(f"{len(made)} symbols, {len(rows)} names, Phosphor {PHOSPHOR}")


if __name__ == "__main__":
    main()
