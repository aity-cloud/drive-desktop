#!/usr/bin/env python3
"""Replace upstream's trademark in translation VALUES of a materialised tree.

    scripts/debrand-translations.py <materialised-tree>

Values only - <source> strings are lookup keys and stay. The one message
whose translations are left alone is upstream's About page: Theme::about()
is overridden in the OEM theme, so those translations are never looked up.
"""
import pathlib
import re
import sys

ABOUT = "Version %1. For more information visit"
tree = pathlib.Path(sys.argv[1])
msg_re = re.compile(r"<message>.*?</message>", re.S)
src_re = re.compile(r"<source>(.*?)</source>", re.S)
tr_re = re.compile(r"(<translation[^>]*>)(.*?)(</translation>)", re.S)

files = n = 0
for ts in sorted(tree.glob("translations/client_*.ts")):
    text = ts.read_text(encoding="utf-8")

    def fix(m: "re.Match[str]") -> str:
        global n
        msg = m.group(0)
        src = src_re.search(msg)
        if src and ABOUT in src.group(1):
            return msg
        def tr(t: "re.Match[str]") -> str:
            global n
            if "ownCloud" not in t.group(2):
                return t.group(0)
            n += 1
            return t.group(1) + t.group(2).replace("ownCloud", "Aity Drive") + t.group(3)
        return tr_re.sub(tr, msg)

    new = msg_re.sub(fix, text)
    if new != text:
        ts.write_text(new, encoding="utf-8")
        files += 1

print(f"debrand-translations: {n} value(s) in {files} file(s)")
left = []
for ts in sorted(tree.glob("translations/client_*.ts")):
    for m in msg_re.finditer(ts.read_text(encoding="utf-8")):
        src = src_re.search(m.group(0))
        if src and ABOUT in src.group(1):
            continue
        for t in tr_re.finditer(m.group(0)):
            if "ownCloud" in t.group(2):
                left.append(f"{ts.name}: {t.group(2)[:80]}")
if left:
    print("debrand-translations: ownCloud still present:\n  " + "\n  ".join(left[:10]))
    sys.exit(1)
