#!/usr/bin/env python3
"""make ui-review: turns /tmp/yap-ui/snapshots into self-contained review pages.

Each shot's light and dark PNGs are shrunk to JPEG (sips) and inlined as data URIs, grouped by the file-name
prefix UISnapshots uses (page, account, settings, sheet, recorder, onboarding); Chinese (-zh) shots get their own
group. A page is kept under 3.8 MB (the share server takes 4 MB); when the shots don't fit, they continue in
review-2.html, review-3.html…
"""
import base64
import html
import os
import re
import subprocess
import sys
import tempfile

# --src DIR and --out NAME (default: the app snapshots → /tmp/yap-ui/review*.html).
def _arg(flag, default):
    return sys.argv[sys.argv.index(flag) + 1] if flag in sys.argv else default


SRC = _arg("--src", "/tmp/yap-ui/snapshots")
OUT_NAME = _arg("--out", "/tmp/yap-ui/review")
OUT = os.path.dirname(OUT_NAME)
LIMIT = 3_800_000
WIDTH = 820  # px; the snapshots are 2x, so this is a bit under the window's point width
QUALITY = 55

GROUPS = [
    ("page", "侧边栏页面"),
    ("account", "Account 各种状态"),
    ("settings", "Settings 分组"),
    ("sheet", "Sheet 与面板"),
    ("recorder", "录音器"),
    ("onboarding", "Onboarding"),
    ("zh", "中文界面"),
    ("site", "官网"),
    ("web", "paygate 页面、邮件和 dashboard（design/web）"),
    ("og", "分享预览（og:image，1200×630）"),
    ("screenshot", "发版截图（design/screenshots）"),
]

STYLE = """
:root {
  --bg: #f3f3f2; --panel: #ffffff; --text: #1d1d1f; --muted: #6e6e73; --line: #d9d9d6;
  font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", sans-serif;
}
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
  --bg: #1c1c1e; --panel: #2a2a2d; --text: #f2f2f2; --muted: #a1a1a6; --line: #3a3a3d; color-scheme: dark; } }
:root[data-theme="dark"] {
  --bg: #1c1c1e; --panel: #2a2a2d; --text: #f2f2f2; --muted: #a1a1a6; --line: #3a3a3d; color-scheme: dark; }
body { background: var(--bg); color: var(--text); margin: 0; padding: 24px 16px 64px; }
main { max-width: 1760px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
.meta { color: var(--muted); font-size: 13px; margin: 0 0 16px; }
nav { display: flex; flex-wrap: wrap; gap: 6px 14px; font-size: 13px; margin-bottom: 24px; }
nav a { color: var(--muted); }
h2 { font-size: 17px; margin: 40px 0 12px; padding-bottom: 6px; border-bottom: 1px solid var(--line); }
figure { margin: 0 0 28px; }
figcaption { font: 600 13px ui-monospace, SFMono-Regular, Menlo, monospace; margin-bottom: 8px; }
.pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 380px), 1fr)); gap: 12px;
  align-items: start; }
.pair img { width: 100%; height: auto; display: block; border: 1px solid var(--line); border-radius: 6px;
  background: var(--panel); }
.pair span { display: block; color: var(--muted); font-size: 12px; margin-bottom: 4px; }
"""


def shots():
    """{base name: {"light": path, "dark": path}} in the order UISnapshots rendered them (page order)."""
    found = {}
    for name in sorted(os.listdir(SRC), key=lambda n: os.path.getmtime(os.path.join(SRC, n))):
        m = re.fullmatch(r"(.+)-(light|dark)\.png", name)
        if m:
            found.setdefault(m.group(1), {})[m.group(2)] = os.path.join(SRC, name)
    return found


def group_of(base):
    group = base.split("-")[0]
    return "zh" if base.endswith("-zh") and group not in ("site", "web", "screenshot") else group


def jpeg(path, tmp):
    out = os.path.join(tmp, os.path.basename(path) + ".jpg")
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", str(QUALITY), "--resampleWidth",
                    str(WIDTH), path, "--out", out], check=True, capture_output=True)
    with open(out, "rb") as f:
        return "data:image/jpeg;base64," + base64.b64encode(f.read()).decode()


def figure(base, uris):
    cells = "".join(f'<div><span>{a}</span><img src="{uris[a]}" alt="{html.escape(base)} {a}" loading="lazy"></div>'
                    for a in ("light", "dark") if a in uris)
    return f'<figure><figcaption>{html.escape(base)}</figcaption><div class="pair">{cells}</div></figure>'


def page(title, sections, part, parts):
    nav = "".join(f'<a href="#{key}">{html.escape(label)}</a>' for key, label, _ in sections)
    body = "".join(f'<h2 id="{key}">{html.escape(label)}</h2>{"".join(figs)}' for key, label, figs in sections)
    meta = f"第 {part} / {parts} 页 · 左浅色右深色 · 离屏渲染，假数据"
    return (f'<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">'
            f"<title>{html.escape(title)}</title><style>{STYLE}</style><main><h1>{html.escape(title)}</h1>"
            f'<p class="meta">{meta}</p><nav>{nav}</nav>{body}</main>')


def main():
    title = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "Yap UI 基线"
    found = shots()
    if not found:
        sys.exit(f"No snapshots in {SRC}; run make ui-snapshots first.")
    order = {key: i for i, (key, _) in enumerate(GROUPS)}
    labels = dict(GROUPS)
    bases = sorted(found, key=lambda b: order.get(group_of(b), len(order)))  # stable: keeps render order

    with tempfile.TemporaryDirectory() as tmp:
        figures = [(group_of(b), figure(b, {a: jpeg(p, tmp) for a, p in found[b].items()})) for b in bases]

    # Fill pages in order until the next figure would pass the limit.
    pages, current, size = [], [], 0
    for key, fig in figures:
        if current and size + len(fig) > LIMIT - 20_000:
            pages.append(current)
            current, size = [], 0
        current.append((key, fig))
        size += len(fig)
    pages.append(current)

    stem = os.path.basename(OUT_NAME)
    for old in os.listdir(OUT):
        if re.fullmatch(re.escape(stem) + r"(-\d+)?\.html", old):
            os.remove(os.path.join(OUT, old))
    for i, figs in enumerate(pages, 1):
        sections = []
        for key, fig in figs:
            if not sections or sections[-1][0] != key:
                sections.append((key, labels.get(key, key), []))
            sections[-1][2].append(fig)
        name = f"{stem}.html" if len(pages) == 1 else f"{stem}-{i}.html"
        path = os.path.join(OUT, name)
        with open(path, "w") as f:
            f.write(page(title, sections, i, len(pages)))
        print(f"{path}  {os.path.getsize(path) / 1_000_000:.2f} MB  {len(figs)} shots")


if __name__ == "__main__":
    main()
