#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build the documentation site.

    docs/build.py [--out DIR] [--serve [PORT]]

The site is a set of static pages. Each page is an HTML fragment in
docs/content with a comment at its top:

    <!--
    title: Options
    description: One sentence for the search results and the meta tag.
    -->

docs/site.toml names the pages and their sequence. docs/theme has the page
template, the style sheet, the script and the fonts.

The script uses only the Python standard library. It stops with an error if
a link between the pages has no target.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import http.server
import json
import re
import shutil
import sys
import tomllib
from dataclasses import dataclass, field
from functools import partial
from pathlib import Path

DOCS = Path(__file__).resolve().parent
CONTENT = DOCS / "content"
THEME = DOCS / "theme"


@dataclass
class Page:
    slug: str
    title: str
    description: str
    body: str
    layout: str = "doc"
    section: str = ""
    toc: list[tuple[int, str, str]] = field(default_factory=list)

    @property
    def url(self) -> str:
        return f"{self.slug}.html"


def fail(message: str) -> None:
    sys.exit(f"docs/build.py: {message}")


def read_page(slug: str) -> Page:
    path = CONTENT / f"{slug}.html"
    if not path.is_file():
        fail(f"no such page: {path}")
    text = path.read_text(encoding="utf-8")
    match = re.match(r"\s*<!--(.*?)-->\s*", text, re.S)
    if not match:
        fail(f"{path}: no header comment")
    meta = {}
    for line in match.group(1).strip().splitlines():
        key, _, value = line.partition(":")
        meta[key.strip()] = value.strip()
    for key in ("title", "description"):
        if not meta.get(key):
            fail(f"{path}: no {key} in the header comment")
    return Page(
        slug=slug,
        title=meta["title"],
        description=meta["description"],
        body=text[match.end() :],
        layout=meta.get("layout", "doc"),
    )


# --- code blocks ------------------------------------------------------------


def span(cls: str, text: str) -> str:
    return f'<span class="{cls}">{text}</span>'


def highlight_command(text: str) -> str:
    """Mark the options and the comment of one command line."""
    comment = ""
    match = re.search(r"(^|\s)#.*$", text)
    if match:
        start = match.start() + len(match.group(1))
        text, comment = text[:start], span("c", text[start:])
    text = re.sub(r"(?<![\w-])(--?[A-Za-z][\w-]*)", lambda m: span("f", m.group(1)), text)
    return text + comment


def highlight(code: str, lang: str) -> str:
    """Add spans to a code block. The code is HTML already."""
    lines = []
    for line in code.split("\n"):
        if lang == "console":
            match = re.match(r"(\$|&gt;) (.*)$", line)
            if match:
                line = span("p", match.group(1)) + " " + highlight_command(match.group(2))
            else:
                line = span("o", line) if line else line
        elif lang == "conf":
            if re.match(r"\s*#", line):
                line = span("c", line)
            else:
                line = re.sub(r"^(\s*)(\w+)(=)", lambda m: m.group(1) + span("k", m.group(2)) + m.group(3), line)
        elif lang == "sh":
            if re.match(r"\s*#", line):
                line = span("c", line)
            else:
                line = highlight_command(line)
        lines.append(line)
    return "\n".join(lines)


LANG_LABEL = {"console": "Terminal", "conf": "Configuration", "sh": "Shell"}


def code_block(match: re.Match[str]) -> str:
    attrs, code = match.group(1), match.group(2)
    lang = re.search(r'data-lang="([^"]*)"', attrs)
    title = re.search(r'data-title="([^"]*)"', attrs)
    lang = lang.group(1) if lang else ""
    label = title.group(1) if title else LANG_LABEL.get(lang, "")
    return (
        '<div class="code">'
        f'<div class="code-head"><span>{label}</span>'
        '<button type="button" class="copy" aria-label="Copy the code">Copy</button></div>'
        f'<pre><code>{highlight(code.strip(chr(10)), lang)}</code></pre></div>'
    )


# --- page body --------------------------------------------------------------


def table_cell(match: re.Match[str]) -> str:
    """Let a long name in a table cell break after an underscore.

    A browser breaks a name such as SRUN_APPTAINER_BIND only in the middle
    of a word, or not at all. The <wbr> elements name the correct points.
    """

    def code(inner: re.Match[str]) -> str:
        return "<code>" + re.sub(r"_(?=\w)", "_<wbr>", inner.group(1)) + "</code>"

    return re.sub(r"<code>([^<]*)</code>", code, match.group(0))


def plain_text(fragment: str) -> str:
    text = re.sub(r"<svg.*?</svg>", " ", fragment, flags=re.S)
    text = re.sub(r'<div class="code-head">.*?</div>', " ", text, flags=re.S)
    text = re.sub(r"<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", html.unescape(text)).strip()


def render_body(page: Page, figure_number: list[int]) -> str:
    body = page.body

    body = re.sub(r"<pre([^>]*)>(.*?)</pre>", code_block, body, flags=re.S)
    body = re.sub(r"<td>.*?</td>", table_cell, body, flags=re.S)
    body = body.replace("<table>", '<div class="table"><table>').replace("</table>", "</table></div>")
    body = re.sub(
        r'<aside class="(note|warn)">',
        lambda m: f'<aside class="callout {m.group(1)}"><span class="callout-label">'
        f'{"Note" if m.group(1) == "note" else "Caution"}</span><div>',
        body,
    )
    body = body.replace("</aside>", "</div></aside>")

    def heading(match: re.Match[str]) -> str:
        level, ident, inner = int(match.group(1)), match.group(2), match.group(3)
        page.toc.append((level, ident, plain_text(inner)))
        return (
            f'<h{level} id="{ident}">{inner}'
            f'<a class="anchor" href="#{ident}" aria-label="Link to this section">#</a></h{level}>'
        )

    body = re.sub(r'<h([23]) id="([^"]+)">(.*?)</h\1>', heading, body, flags=re.S)
    if page.layout == "doc" and re.search(r"<h[23](?! id=)", body):
        fail(f"{page.slug}: a heading has no id")

    def figure(match: re.Match[str]) -> str:
        figure_number[0] += 1
        return f'<figure class="diagram" data-dwg="DWG {figure_number[0]:02d}">'

    body = re.sub(r'<figure class="diagram">', figure, body)
    return body


def search_records(page: Page, body: str) -> list[dict[str, str]]:
    """One record for the start of the page and one for each section."""
    records = []
    parts = re.split(r'(<h[23] id="[^"]+">.*?</h[23]>)', body, flags=re.S)
    heading, ident = "", ""
    for part in parts:
        match = re.match(r'<h[23] id="([^"]+)">(.*?)</h[23]>', part, re.S)
        if match:
            ident = match.group(1)
            heading = plain_text(re.sub(r'<a class="anchor".*?</a>', "", match.group(2)))
            continue
        text = plain_text(part)
        if not text and not heading:
            continue
        records.append(
            {
                "url": page.url + (f"#{ident}" if ident else ""),
                "page": page.title,
                "heading": heading,
                "text": text,
            }
        )
    return records


# --- site -------------------------------------------------------------------


def fill(template: str, values: dict[str, str]) -> str:
    def value(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in values:
            fail(f"the template uses an unknown value: {key}")
        return values[key]

    return re.sub(r"\{\{(\w+)\}\}", value, template)


def check_links(out: Path, pages: dict[str, str]) -> None:
    ids = {name: set(re.findall(r'\sid="([^"]+)"', text)) for name, text in pages.items()}
    for name, text in pages.items():
        for href in re.findall(r'href="([^"]+)"', text):
            if re.match(r"(https?:|mailto:|assets/)", href):
                continue
            target, _, anchor = href.partition("#")
            target = target or name
            if target not in pages:
                fail(f"{name}: link to a page that does not exist: {href}")
            if anchor and anchor not in ids[target]:
                fail(f"{name}: link to a section that does not exist: {href}")


def build(out: Path) -> None:
    site = tomllib.loads((DOCS / "site.toml").read_text(encoding="utf-8"))
    template = (THEME / "page.html").read_text(encoding="utf-8")

    sections = site["section"]
    ordered: list[Page] = []
    for section in sections:
        for slug in section["pages"]:
            page = read_page(slug)
            page.section = section["name"]
            ordered.append(page)
    home = read_page("index")

    listed = {page.slug for page in ordered} | {"index"}
    for path in CONTENT.glob("*.html"):
        if path.stem not in listed:
            fail(f"{path.name} is not in site.toml")

    if out.exists():
        shutil.rmtree(out)
    shutil.copytree(THEME / "assets", out / "assets")

    digest = hashlib.sha256()
    for path in sorted((out / "assets").rglob("*")):
        if path.is_file():
            digest.update(path.read_bytes())
    version = digest.hexdigest()[:10]

    top_nav = "".join(
        f'<a href="{section["pages"][0]}.html" data-section="{html.escape(section["name"])}">'
        f'{html.escape(section["name"])}</a>'
        for section in sections
    )

    def sidebar(current: Page) -> str:
        parts = []
        for section in sections:
            parts.append(f'<div class="side-group">{html.escape(section["name"])}</div>')
            for slug in section["pages"]:
                page = next(p for p in ordered if p.slug == slug)
                on = ' class="on" aria-current="page"' if page is current else ""
                parts.append(f'<a href="{page.url}"{on}>{html.escape(page.title)}</a>')
        return "".join(parts)

    common = {
        "site": html.escape(site["title"]),
        "tagline": html.escape(site["tagline"]),
        "repo": site["repo"],
        "repo_tree": f'{site["repo"]}/tree/{site["branch"]}',
        "slurm": html.escape(site["slurm"]),
        "version": version,
        "top_nav": top_nav,
    }

    written: dict[str, str] = {}
    records: list[dict[str, str]] = []
    figure_number = [0]

    for index, page in enumerate([home] + ordered):
        body = render_body(page, figure_number)
        is_home = page is home
        # The home page repeats the content of the other pages.
        if not is_home:
            records += search_records(page, body)
        previous = ordered[index - 2] if index >= 2 else None
        following = ordered[index] if index < len(ordered) else None

        toc = "".join(
            f'<a href="#{ident}" class="toc-{level}">{html.escape(text)}</a>'
            for level, ident, text in page.toc
        )
        pager = ""
        if not is_home:
            if previous:
                pager += (
                    f'<a class="pager-prev" href="{previous.url}"><span>Previous</span>'
                    f"{html.escape(previous.title)}</a>"
                )
            if following:
                pager += (
                    f'<a class="pager-next" href="{following.url}"><span>Next</span>'
                    f"{html.escape(following.title)}</a>"
                )

        text = fill(
            template,
            common
            | {
                "title": html.escape(page.title if not is_home else site["tagline"]),
                "page_title": html.escape(page.title),
                "description": html.escape(page.description),
                "layout": "home" if is_home else "doc",
                "section": html.escape(page.section),
                "sidebar": sidebar(page),
                "toc": toc,
                "pager": pager,
                "edit": f'{site["repo"]}/blob/{site["branch"]}/docs/content/{page.slug}.html',
                "body": body,
            },
        )
        written[page.url] = text

    check_links(out, written)
    for name, text in written.items():
        (out / name).write_text(text, encoding="utf-8")

    (out / "assets" / "search.json").write_text(
        json.dumps(records, ensure_ascii=False, separators=(",", ":")), encoding="utf-8"
    )
    (out / ".nojekyll").write_text("", encoding="utf-8")
    print(f"{len(written)} pages, {len(records)} search records: {out}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Build the documentation site.")
    parser.add_argument("--out", type=Path, default=DOCS.parent / "_site", help="output directory")
    parser.add_argument("--serve", nargs="?", const=8000, type=int, metavar="PORT", help="serve the site after the build")
    args = parser.parse_args()

    build(args.out)

    if args.serve:
        handler = partial(http.server.SimpleHTTPRequestHandler, directory=str(args.out))
        print(f"http://localhost:{args.serve}/")
        http.server.ThreadingHTTPServer(("", args.serve), handler).serve_forever()


if __name__ == "__main__":
    main()
