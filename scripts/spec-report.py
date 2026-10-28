#!/usr/bin/env python3
"""Compare Quick Markdown's rendering of the CommonMark / GFM spec examples
with the expected HTML.

Run the tests first (they write spec-results.json into the app's sandbox):

    xcodebuild -project QuickMarkdown.xcodeproj -scheme QuickMarkdown \
      -destination 'platform=macOS' test
    python3 scripts/spec-report.py            # summary by suite and section
    python3 scripts/spec-report.py -v         # also print every failure
    python3 scripts/spec-report.py -s Tables  # failures in matching sections
    python3 scripts/spec-report.py --check    # exit 1 if anything fails (CI)

HTML is normalised the way CommonMark's own test runner does (whitespace,
attribute order, entities, void tags). Cosmetic additions Quick Markdown
makes on purpose are ignored: heading anchor ids, syntax-highlighting
spans and classes, GitHub's task-list-item class, and the task checkbox
index used by the Preview. A <strong> nested directly in another <strong>
counts as one (it looks the same, and the two spec suites disagree).
"""
import argparse
import html
import json
import os
import re
import sys
from collections import defaultdict
from html.parser import HTMLParser

# Examples where Quick Markdown deliberately follows GitHub rather than the
# example's expected output. They're reported separately, not as failures.
DELIBERATE = {
    "tag filter": ("GitHub's tag filter shows <script>, <style>, <textarea> "
                   "and similar tags as text",
                   {("gfm-spec", n) for n in (140, 141, 142, 145, 147)}
                   | {("commonmark-0.31.2-spec", n) for n in (170, 171, 172, 173, 176, 178)}),
    "autolinks": ("GitHub's autolink extension links bare URLs and emails, "
                  "which these core-spec examples show without the extension",
                  {("gfm-spec", n) for n in (610, 614, 616, 619, 620)}
                  | {("commonmark-0.31.2-spec", n) for n in (602, 606, 608, 611, 612)}),
    "parser": ("cmark (and GitHub) follow the 0.29 spec here; CommonMark 0.31 "
               "changed invalid code points and currency-symbol emphasis",
               {("commonmark-0.31.2-spec", n) for n in (28, 354)}),
    "footnote backref": ("a footnote's back-link after a code block sits in its "
                         "own paragraph (it looks the same)",
                         {("cmark-extensions", 23)}),
}

RESULTS = os.path.expanduser(
    "~/Library/Containers/com.neiljohn.quickmarkdown/Data/tmp/spec-results.json")

BLOCK = {"article", "header", "aside", "hgroup", "blockquote", "hr", "iframe",
         "body", "li", "map", "button", "object", "canvas", "ol", "caption",
         "output", "col", "p", "colgroup", "pre", "dd", "progress", "div",
         "section", "dl", "table", "td", "dt", "tbody", "embed", "textarea",
         "fieldset", "tfoot", "figcaption", "th", "figure", "thead", "footer",
         "tr", "form", "ul", "h1", "h2", "h3", "h4", "h5", "h6", "video",
         "script", "style", "html", "head", "title", "meta", "link", "br"}
VOID = {"br", "hr", "img", "input", "meta", "link", "col", "area", "base",
        "embed", "source", "track", "wbr"}
HEADINGS = {"h1", "h2", "h3", "h4", "h5", "h6"}


class Normaliser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.out = []
        self.in_pre = 0
        self.skip_span = []   # stack: True for highlight spans we drop
        self.strong_depth = 0

    def text(self, data):
        if not self.in_pre:
            data = re.sub(r"\s+", " ", data)
        self.out.append(("text", data))

    def handle_starttag(self, tag, attrs):
        if tag == "strong":
            self.strong_depth += 1
            if self.strong_depth > 1:
                return
        if tag == "span":
            cls = dict(attrs).get("class") or ""
            drop = cls.startswith("hljs")
            self.skip_span.append(drop)
            if drop:
                return
        cleaned = []
        for k, v in attrs:
            if k in ("style", "data-task-index"):
                continue
            if k == "id" and tag in HEADINGS:
                continue
            if k == "class":
                v = " ".join(c for c in (v or "").split()
                             if c not in ("hljs", "task-list-item")) or None
                if v is None:
                    continue
            cleaned.append((k, "" if v is None else v))
        cleaned.sort()
        if tag == "pre":
            self.in_pre += 1
        self.out.append(("start", tag, tuple(cleaned)))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.handle_endtag(tag)

    def handle_endtag(self, tag):
        if tag == "strong":
            self.strong_depth -= 1
            if self.strong_depth > 0:
                return
        if tag == "span" and self.skip_span:
            if self.skip_span.pop():
                return
        if tag in VOID:
            return
        if tag == "pre":
            self.in_pre = max(0, self.in_pre - 1)
        self.out.append(("end", tag))

    def handle_data(self, data):
        self.text(data)

    def handle_entityref(self, name):
        self.text(html.unescape("&%s;" % name))

    def handle_charref(self, name):
        self.text(html.unescape("&#%s;" % name))

    def handle_comment(self, data):
        self.out.append(("raw", "<!--%s-->" % data))

    def handle_decl(self, decl):
        self.out.append(("raw", "<!%s>" % decl))

    def handle_pi(self, data):
        self.out.append(("raw", "<?%s>" % data))

    def unknown_decl(self, data):
        self.out.append(("raw", "<![%s]>" % data))


def normalise(markup):
    p = Normaliser()
    try:
        p.feed(markup)
        p.close()
    except Exception:
        return markup.strip()
    # Merge adjacent text, then trim whitespace next to block-level tags.
    tokens = []
    for t in p.out:
        if t[0] == "text" and tokens and tokens[-1][0] == "text":
            tokens[-1] = ("text", tokens[-1][1] + t[1])
        else:
            tokens.append(t)
    rendered = []
    for i, t in enumerate(tokens):
        if t[0] == "text":
            s = t[1]
            prev = tokens[i - 1] if i else None
            nxt = tokens[i + 1] if i + 1 < len(tokens) else None
            if prev is None or (prev[0] in ("start", "end") and prev[1] in BLOCK):
                s = s.lstrip()
            if nxt is None or (nxt[0] in ("start", "end") and nxt[1] in BLOCK):
                s = s.rstrip()
            rendered.append(html.escape(s, quote=False))
        elif t[0] == "start":
            attrs = "".join(' %s="%s"' % (k, html.escape(v)) for k, v in t[2])
            rendered.append("<%s%s>" % (t[1], attrs))
        elif t[0] == "end":
            rendered.append("</%s>" % t[1])
        else:
            rendered.append(t[1])
    return "".join(rendered)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-v", "--verbose", action="store_true")
    ap.add_argument("-s", "--section", help="show failures in sections matching this")
    ap.add_argument("-u", "--suite", help="only this suite")
    ap.add_argument("--json", help="write failures to this file")
    ap.add_argument("--check", action="store_true", help="exit 1 if any example fails")
    ap.add_argument("results", nargs="?", default=RESULTS)
    args = ap.parse_args()
    deliberate = {key: name for name, (_, keys) in DELIBERATE.items() for key in keys}
    deliberate_hits = defaultdict(int)

    results = json.load(open(args.results))
    by_suite = defaultdict(lambda: [0, 0])
    by_section = defaultdict(lambda: [0, 0])
    failures = []
    for r in results:
        if args.suite and r["suite"] != args.suite:
            continue
        expected = r["expected"].strip()
        ok = expected.lower() == "<ignore>" or normalise(r["actual"]) == normalise(expected)
        if not ok and (r["suite"], r["example"]) in deliberate:
            deliberate_hits[deliberate[(r["suite"], r["example"])]] += 1
            ok = True
        key = (r["suite"], r["section"])
        by_suite[r["suite"]][0 if ok else 1] += 1
        by_section[key][0 if ok else 1] += 1
        if not ok:
            failures.append(r)

    for suite, (p, f) in by_suite.items():
        print("%-26s %4d / %4d passed (%.1f%%)" % (suite, p, p + f, 100.0 * p / (p + f)))
    for name, count in deliberate_hits.items():
        print("  (%d counted as passing: %s)" % (count, DELIBERATE[name][0]))
    print()
    for (suite, section), (p, f) in sorted(by_section.items(), key=lambda kv: -kv[1][1]):
        if f:
            print("  %-24s %-45s %3d failing of %3d" % (suite, section[:45], f, p + f))

    shown = [r for r in failures
             if args.verbose or (args.section and args.section.lower() in r["section"].lower())]
    for r in shown:
        print("\n=== %s #%d — %s" % (r["suite"], r["example"], r["section"]))
        print("--- markdown\n" + r["markdown"].rstrip("\n"))
        print("--- expected\n" + normalise(r["expected"]))
        print("--- actual\n" + normalise(r["actual"]))
    if args.json:
        json.dump(failures, open(args.json, "w"), indent=1, ensure_ascii=False)
    return 1 if args.check and failures else 0


if __name__ == "__main__":
    sys.exit(main())
