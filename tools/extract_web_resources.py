#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from urllib.parse import urljoin, urlparse


@dataclass(frozen=True)
class Link:
    url: str
    attr: str
    tag: str


_ATTR_RE = re.compile(
    r"""(?P<tag><(?P<tagname>[a-zA-Z0-9:_-]+)\b[^>]*?)\s(?P<attr>href|src)\s*=\s*(?P<q>["'])(?P<val>.*?)(?P=q)""",
    re.IGNORECASE | re.DOTALL,
)


def _iter_links(html: str, base_url: str) -> Iterable[Link]:
    for m in _ATTR_RE.finditer(html):
        tagname = (m.group("tagname") or "").lower()
        attr = (m.group("attr") or "").lower()
        raw = (m.group("val") or "").strip()
        if not raw:
            continue
        # Skip in-page anchors and javascript: URLs.
        if raw.startswith("#") or raw.lower().startswith("javascript:"):
            continue
        yield Link(url=urljoin(base_url, raw), attr=attr, tag=tagname)


def _classify(url: str) -> str:
    p = urlparse(url)
    path = p.path.lower()
    if path.endswith(".css"):
        return "css"
    if path.endswith(".js") or path.endswith(".mjs"):
        return "js"
    if any(path.endswith(ext) for ext in (".png", ".jpg", ".jpeg", ".webp", ".svg", ".ico", ".gif")):
        return "image"
    if any(path.endswith(ext) for ext in (".woff2", ".woff", ".ttf", ".otf", ".eot")):
        return "font"
    if path.endswith(".json"):
        return "json"
    if path.endswith(".xml"):
        return "xml"
    if path.endswith(".wasm"):
        return "wasm"
    return "other"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--html", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    html_path = Path(args.html)
    out_path = Path(args.out)
    html = html_path.read_text(encoding="utf-8", errors="replace")

    links = sorted({l.url: l for l in _iter_links(html, args.base_url)}.values(), key=lambda l: l.url)
    categorized: dict[str, list[dict[str, str]]] = {}
    for l in links:
        kind = _classify(l.url)
        categorized.setdefault(kind, []).append({"url": l.url, "tag": l.tag, "attr": l.attr})

    report = {
        "base_url": args.base_url,
        "source_html": str(html_path),
        "total_links": len(links),
        "by_type_counts": {k: len(v) for k, v in sorted(categorized.items())},
        "links": categorized,
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

