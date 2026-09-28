"""Build one self-contained review board for the yap-launch series from brand-studio's share-review.html.

    uv run --with markdown python3 marketing/review/build.py <round> <brand-studio share-review.html> <out.html>

Items are listed in round-<n>.json next to this file. Docs are rendered from Markdown, the site draft is inlined
into an iframe (CSS and images as data URIs), images are embedded. The share server stores bytes only, so
everything must be inside the one file (≤ 4 MB).
"""
import base64, html, json, mimetypes, re, subprocess, sys
from pathlib import Path

import markdown

ROOT = Path(__file__).resolve().parents[2]
rnd, template, out = int(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
spec = json.loads((Path(__file__).parent / f"round-{rnd}.json").read_text())


def data_uri(path, max_width=None):
    path = Path(path)
    if max_width and path.suffix == ".png":
        tmp = Path(f"/tmp/claude-review-{path.stem}.jpg")
        subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "--resampleWidth",
                        str(max_width), str(path), "--out", str(tmp)], check=True, capture_output=True)
        path = tmp
    mime = mimetypes.guess_type(path.name)[0]
    return f"data:{mime};base64,{base64.b64encode(path.read_bytes()).decode()}"


def md(path):
    text = re.sub(r"<!--.*?-->", "", (ROOT / path).read_text(), flags=re.S)
    return markdown.markdown(text, extensions=["tables", "fenced_code"])


def site_draft(path):
    page = (ROOT / path).read_text()
    for css in ("tokens.css", "site.css"):
        page = page.replace(f'<link rel="stylesheet" href="../../site/{css}">',
                            f"<style>{(ROOT / 'site' / css).read_text()}</style>")
    page = re.sub(r'<link rel="(icon|apple-touch-icon|manifest)"[^>]*>\n?', "", page)
    for ref in sorted(set(re.findall(r'"\.\./\.\./site/(assets/[^"]+)"', page))):
        page = page.replace(f'"../../site/{ref}"', f'"{data_uri(ROOT / "site" / ref)}"')
    return page


items = []
for it in spec["items"]:
    entry = {"id": it["id"], "concept": html.escape(it["concept"])}
    if "doc" in it:
        entry["doc"] = md(it["doc"])
    elif "site" in it:
        entry["frame"] = site_draft(it["site"])
    elif "image" in it:
        entry["jpg"] = data_uri(ROOT / it["image"] if not it["image"].startswith("/") else it["image"], 1200)
    items.append(entry)

page = template.read_text()
# The template has no charset declaration; without it the page is read as Latin-1 wherever the server omits one.
page = page.replace("<title>org mark · round 1 评审</title>", f'<meta charset="utf-8">\n<title>{spec["title"]}</title>')
page = page.replace("org mark · round 1 · 24 candidates", f"yap-launch · round {rnd} · {len(items)} items")
page = page.replace("Org 标志 Round 1 评审板", spec["title"])
page = page.replace("__GOAL__", spec["goal"])
page = page.replace("const ROUND = 1;", f"const ROUND = {rnd};")
page = page.replace("const ITEMS = __ITEMS_JSON__;", "const ITEMS = " + json.dumps(items, ensure_ascii=False).replace("</", "<\\/") + ";")
# Documents and the site draft need the full width and a readable body; images keep the template's card.
page = page.replace("</style>", """  .card.doc{grid-column:1/-1;}
  .card.doc details{border-top:1px solid var(--line);}
  .card.doc summary{cursor:pointer;padding:10px 14px;font-weight:600;}
  .doc-body{padding:4px 22px 18px;max-width:80ch;font-size:14.5px;}
  .doc-body table{border-collapse:collapse;font-size:13px;display:block;overflow-x:auto;}
  .doc-body th,.doc-body td{border:1px solid var(--line);padding:5px 8px;text-align:left;vertical-align:top;}
  .doc-body pre{background:#fff;border:1px solid var(--line);border-radius:6px;padding:10px;overflow-x:auto;font-size:12.5px;}
  .doc-body code{font-family:ui-monospace,"SF Mono",Menlo,monospace;font-size:.92em;}
  .frame{width:100%;height:900px;border:0;display:block;background:#fff;}
</style>""", 1)
page = page.replace("""    const wide = it.id === "r1-p10" ? " wide" : "";
    card.innerHTML =
      '<div class="stage'+wide+'">' + stageHTML(it) + '</div>' +""", """    const isDoc = !!(it.doc || it.frame);
    if (isDoc) card.classList.add("doc");
    const body = it.doc ? '<details><summary>展开全文</summary><div class="doc-body">' + it.doc + '</div></details>'
      : it.frame ? '<iframe class="frame" title="' + it.concept + '"></iframe>' : '';
    card.innerHTML =
      (isDoc ? '' : '<div class="stage">' + stageHTML(it) + '</div>') +""")
page = page.replace("""      '</div>';
    g.appendChild(card);""", """      '</div>' + (isDoc ? body : '');
    g.appendChild(card);
    if (it.frame) card.querySelector("iframe").srcdoc = it.frame;""", 1)
assert "__ITEMS_JSON__" not in page and "isDoc" in page and "srcdoc" in page
out.write_text(page)
print(f"{out} {out.stat().st_size / 1e6:.2f} MB, {len(items)} items")
