#!/usr/bin/env python3
"""Embed README.md into docs.html so the docs page works offline (file:// URLs).

Can be run standalone or called by build_release.sh. Works whether docs.html
contains the {{README_CONTENT}} placeholder or already has content embedded
from a previous run.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent
HTML_PATH = ROOT / "docs" / "index.html"
README_PATH = ROOT / "README.md"
INSTRUMENTS_PATH = ROOT / "INSTRUMENTS.md"
VST_PATH = ROOT / "VST.md"

PLACEHOLDER = "{{README_CONTENT}}"
# Regex to match everything between the <script id="readme-source"> tags
SCRIPT_RE = re.compile(
    r'(<script id="readme-source" type="text/plain">)\n.*?\n(</script>)',
    re.DOTALL,
)


def build():
    readme = README_PATH.read_text(encoding="utf-8")
    instruments = INSTRUMENTS_PATH.read_text(encoding="utf-8")
    vst = VST_PATH.read_text(encoding="utf-8")
    combined = readme + "\n\n---\n\n" + instruments + "\n\n---\n\n" + vst
    # Escape </script> inside the embedded block so the browser doesn't break
    content_safe = combined.replace("</script>", "<\\/script>")

    html = HTML_PATH.read_text(encoding="utf-8")

    if PLACEHOLDER in html:
        # First-time build from template
        html = html.replace(PLACEHOLDER, content_safe)
    elif SCRIPT_RE.search(html):
        # Re-embed into already-baked file (use lambda to avoid regex escaping issues)
        html = SCRIPT_RE.sub(
            lambda m: f"{m.group(1)}\n{content_safe}\n{m.group(2)}", html
        )
    else:
        raise SystemExit(
            "Could not find placeholder or readme-source script tag in docs.html."
        )

    HTML_PATH.write_text(html, encoding="utf-8")
    print(f"docs/index.html updated ({len(combined)} chars embedded from README.md + INSTRUMENTS.md + VST.md)")


if __name__ == "__main__":
    build()
