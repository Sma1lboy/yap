#!/usr/bin/env python3
"""Prepend a release <item> to the Sparkle appcast.

usage: appcast.py APPCAST VERSION BUILD 'sparkle:edSignature="..." length="..."'
The last argument is the raw output of Sparkle's `bin/sign_update`.
"""
import re
import sys
import xml.etree.ElementTree as ET
from email.utils import formatdate

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPO = "https://github.com/Sma1lboy/yap"
MAX_ITEMS = 10

ET.register_namespace("sparkle", SPARKLE)


def add_release(path, version, build, sign_output):
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
    tree.write(path, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    add_release(*sys.argv[1:])
