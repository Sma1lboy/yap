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
    assert top.find("description") is None  # no notes file → no description

    # Release notes: the HTML file becomes a CDATA <description>, even with "]]>" and "&" in it, and an earlier
    # item's notes survive the next release as CDATA.
    notes = os.path.join(d, "notes.html")
    html = '<h1>Yap 2.0.0</h1>\n<ul><li>Faster &amp; smaller</li><li>odd ]]> text</li></ul>'
    with open(notes, "w", encoding="utf-8") as f:
        f.write(html + "\n")
    subprocess.run([sys.executable, os.path.join(HERE, "appcast.py"), path, "2.0.0", "2000",
                    'sparkle:edSignature="SIGN==" length="1"', notes], check=True)
    subprocess.run([sys.executable, os.path.join(HERE, "appcast.py"), path, "2.0.1", "2001",
                    'sparkle:edSignature="SIGN1==" length="2"'], check=True)
    raw = open(path, encoding="utf-8").read()
    assert raw.count("<![CDATA[") == 2, raw.count("<![CDATA[")  # the "]]>" split makes two sections
    items = ET.parse(path).getroot().find("channel").findall("item")
    assert items[0].findtext("title") == "Yap 2.0.1" and items[0].find("description") is None
    assert items[1].findtext("title") == "Yap 2.0.0" and items[1].findtext("description") == html
print("ok")
