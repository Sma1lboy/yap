#!/usr/bin/env python3
"""Run scripts/appcast.py against a copy of the repo appcast and check the result."""
import os
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
S = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "appcast.xml")
    shutil.copy(os.path.join(HERE, "..", "appcast.xml"), path)
    for i in range(12):
        subprocess.run([sys.executable, os.path.join(HERE, "appcast.py"), path,
                        f"1.0.{i}", str(1000 + i),
                        f'sparkle:edSignature="SIG{i}==" length="{100 + i}"'], check=True)

    channel = ET.parse(path).getroot().find("channel")
    items = channel.findall("item")
    assert len(items) == 10, len(items)
    top = items[0]
    assert top.findtext("title") == "Yap 1.0.11"
    assert top.findtext(f"{S}version") == "1011"
    assert top.findtext(f"{S}shortVersionString") == "1.0.11"
    assert top.findtext(f"{S}minimumSystemVersion") == "15.0"
    assert top.findtext("link") == "https://github.com/Sma1lboy/yap/releases/tag/v1.0.11"
    enc = top.find("enclosure")
    assert enc.get("url") == "https://github.com/Sma1lboy/yap/releases/download/v1.0.11/Yap.zip"
    assert enc.get(f"{S}edSignature") == "SIG11=="
    assert enc.get("length") == "111"
    assert items[-1].findtext("title") == "Yap 1.0.2"
    assert channel.findtext("title") == "Yap"
print("ok")
