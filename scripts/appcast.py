#!/usr/bin/env python3
"""Prepend a release <item> to the Sparkle appcast.

usage: appcast.py APPCAST VERSION BUILD 'sparkle:edSignature="..." length="..."' [NOTES_HTML_FILE]
The fourth argument is the raw output of Sparkle's `bin/sign_update`. The optional fifth is an HTML file with the
release notes; it becomes the item's <description> (CDATA), which Sparkle shows in the update dialog.
"""
import re
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "https://github.com/Sma1lboy/yap"
MAX_ITEMS = 10

ET.register_namespace("sparkle", SPARKLE)


def add_release(path, version, build, sign_output, notes_path=None):
    sig = re.search(r'sparkle:edSignature="([^"]+)"', sign_output)
    length = re.search(r'length="(\d+)"', sign_output)
    if not sig or not length:
        sys.exit(f"cannot parse sign_update output: {sign_output!r}")

    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
    tag = f"v{version}"

    item = ET.Element("item")
    for name, text in [
        ("title", f"Yap {version}"),
        ("pubDate", formatdate(usegmt=True)),
        (f"{{{SPARKLE}}}version", str(build)),
        (f"{{{SPARKLE}}}shortVersionString", version),
        (f"{{{SPARKLE}}}minimumSystemVersion", "15.0"),
        ("link", f"{REPO}/releases/tag/{tag}"),
    ]:
        ET.SubElement(item, name).text = text
    if notes_path:
        with open(notes_path, encoding="utf-8") as f:
            notes = f.read().strip()
        if notes:
            ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {
        "url": f"{REPO}/releases/download/{tag}/Yap.zip",
        f"{{{SPARKLE}}}edSignature": sig.group(1),
        "length": length.group(1),
        "type": "application/octet-stream",
    })

    items = channel.findall("item")
    first = list(channel).index(items[0]) if items else len(channel)
    channel.insert(first, item)
    for old in channel.findall("item")[MAX_ITEMS:]:
        channel.remove(old)

    ET.indent(tree, space="    ")
    write_with_cdata(tree, path)


def write_with_cdata(tree, path):
    """ElementTree can't emit CDATA, so each <description> (new or from earlier releases) is written as a
    placeholder and swapped for a CDATA section, keeping the HTML readable in the appcast."""
    descriptions = {}
    for i, element in enumerate(tree.getroot().iter("description")):
        placeholder = f"@@APPCAST_DESCRIPTION_{i}@@"
        descriptions[placeholder] = element.text or ""
        element.text = placeholder
    xml = ET.tostring(tree.getroot(), encoding="unicode")
    for placeholder, html in descriptions.items():
        # "]]>" can't appear inside CDATA: split it across two sections.
        xml = xml.replace(placeholder, "<![CDATA[" + html.replace("]]>", "]]]]><![CDATA[>") + "]]>")
    with open(path, "w", encoding="utf-8") as f:
        f.write("<?xml version='1.0' encoding='utf-8'?>\n" + xml)


if __name__ == "__main__":
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    add_release(*sys.argv[1:])
