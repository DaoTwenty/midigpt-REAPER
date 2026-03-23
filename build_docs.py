#!/usr/bin/env python3
"""Embed README.md into docs.html so the docs page works offline (file:// URLs).

Can be run standalone or called by build_release.sh. Works whether docs.html
contains the {{README_CONTENT}} placeholder or already has content embedded
from a previous run.
"""

import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent
HTML_PATH = ROOT / "docs.html"
README_PATH = ROOT / "README.md"

PLACEHOLDER = "{{README_CONTENT}}"
# Regex to match everything between the <script id="readme-source"> tags
SCRIPT_RE = re.compile(
    r'(<script id="readme-source" type="text/plain">)\n.*?\n(</script>)',
    re.DOTALL,
)


def build():
    readme = README_PATH.read_text(encoding="utf-8")
    # Escape </script> inside the embedded block so the browser doesn't break
    readme_safe = readme.replace("</script>", "<\\/script>")

    html = HTML_PATH.read_text(encoding="utf-8")

    if PLACEHOLDER in html:
        # First-time build from template
        html = html.replace(PLACEHOLDER, readme_safe)
    elif SCRIPT_RE.search(html):
        # Re-embed into already-baked file (use lambda to avoid regex escaping issues)
        html = SCRIPT_RE.sub(
            lambda m: f"{m.group(1)}\n{readme_safe}\n{m.group(2)}", html
        )
    else:
        raise SystemExit(
            "Could not find placeholder or readme-source script tag in docs.html."
        )

    HTML_PATH.write_text(html, encoding="utf-8")
    print(f"docs.html updated ({len(readme)} chars embedded from README.md)")


if __name__ == "__main__":
    build()
