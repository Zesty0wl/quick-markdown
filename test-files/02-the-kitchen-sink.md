---
title: The Kitchen Sink
subtitle: Every Markdown construct Quick Markdown is supposed to render, all in one place
author: The Maintainer
date: 2026-05-21
draft: false
---

# The Kitchen Sink

> If it's in CommonMark or GitHub-Flavoured Markdown, it should show up
> somewhere on this page. If it doesn't, [open an issue][issues] and we'll
> argue about it.

[issues]: https://github.com/Zesty0wl/quick-markdown/issues

This file exists so that, after touching anything in the renderer, you can
open it, scroll once, and notice immediately if something is on fire.

It is dense, deliberately. The Welcome file is the brochure; this is the
spec sheet.

---

## 1. Headings, all six of them

# Heading 1 — for the page title
## Heading 2 — for the major sections
### Heading 3 — for the subsections
#### Heading 4 — for the sub-subsections
##### Heading 5 — for the people who really like nesting
###### Heading 6 — basically just bold text with delusions of grandeur

Setext headings, because some people still write them:

Heading 1, the old-fashioned way
================================

Heading 2, the old-fashioned way
--------------------------------

---

## 2. Paragraphs and breaks

Paragraphs are separated by **blank lines**. This is one paragraph that
contains a soft line break — the kind you get
from pressing Return once without a blank line in between. Most renderers
collapse this to a space; we do too.

A hard line break uses two trailing spaces (you can't see them, that's the
joke) or a trailing backslash.\
This is on a new line, courtesy of `\`.

Long lines wrap on their own. The quick brown fox jumps over the lazy
dog, who would frankly rather be sleeping, because being lazy is, by
definition, his whole brand and being jumped over is — at best — a mild
inconvenience that interrupts his nap and — at worst — an indignity that
calls into question the entire ordering of the food chain.

---

## 3. Emphasis, the inline cast

Plain text, **bold text**, *italic text*, ***bold italic***,
~~strikethrough~~, and `inline code` all play together nicely.

Underscores work too: _italic_, __bold__, ___bold italic___.

You can **mix `code` and *italic* inside bold**, which is the kind of thing
that looks fine in the editor and ruins your day in Word, but pastes
correctly here because we hand-build the attributed string.

Backslash escapes: \*not italic\*, \`not code\`, \# not a heading,
\[not a link\](nope).

---

## 4. Links

- Inline link: [Quick Markdown on GitHub](https://github.com/Zesty0wl/quick-markdown)
- Inline link with title: [hover for a tooltip](https://example.com "I am a title attribute")
- Reference link: [the same repo, but via a reference][repo]
- Autolink (angle brackets): <https://example.com>
- Bare URL inside text: https://example.com — this *may* autolink depending
  on the parser; both behaviours are acceptable.
- Email autolink: <hello@example.com>

[repo]: https://github.com/Zesty0wl/quick-markdown "Quick Markdown"

---

## 5. Lists

### Unordered, three ways

- Item with a dash
- Another dashed item
  - Nested with two-space indent
    - Triple-nested, because we can
- Back to the top level

* Item with a star
* And another
+ Item with a plus, mixed in for chaos
+ Plus signs are valid Markdown. Pass it on.

### Ordered, with attitude

1. First
2. Second
3. Third
   1. Nested first
   2. Nested second
4. Fourth

Ordered list with a non-1 start (renderer should respect or at least not
panic):

7. Seven
8. Eight
9. Nine

### Task lists, the only kind that matters

- [x] Open this file
- [x] Confirm checkboxes render
- [ ] Tick this and save
  - [ ] Nested task, still unchecked
  - [x] Nested task, checked
- [ ] Walk away triumphant

### Multi-paragraph list items

1. First item, with a single line.

2. Second item, with **two** paragraphs.

   This second paragraph is indented four spaces under the list marker.
   It should render as a continuation of item 2, not as a new top-level
   paragraph.

3. Third item, with a fenced code block inside:

   ```python
   def hello(name: str) -> str:
       return f"Hello, {name}."
   ```

4. Fourth item, with a blockquote inside:

   > Lists can contain blockquotes. Blockquotes can contain lists.
   > It's turtles all the way down.

---

## 6. Block quotes

> A single-line quote.

> A multi-line quote that wraps. The Markdown spec says a `>` at the start
> of each line keeps the quote going. Quick Markdown agrees.

> ### Quotes can contain headings.
>
> *And inline formatting.* And **bold**. And `code`.
>
> - And lists.
> - With multiple items.

> > Quotes can also be **nested**.
> >
> > > And nested *again*. (At which point you should probably ask whether
> > > you really need this many levels of indirection in a piece of writing.)

---

## 7. Code

### Inline code

Run `xcodebuild -scheme QuickMarkdown` and pray.

### Fenced code with a language

```swift
import AppKit

final class HelloView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let text = "Hello, AppKit."
        text.draw(at: NSPoint(x: 12, y: 12),
                  withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
    }
}
```

```python
# Same idea, different language.
def fib(n: int) -> int:
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a

print([fib(i) for i in range(10)])
```

```bash
# A shell snippet, because everyone has one of those.
shasum -a 256 'Quick Markdown-1.0.2.pkg'
```

```json
{
  "name": "quick-markdown",
  "version": "1.0.2",
  "vibes": "immaculate"
}
```

### Fenced code with no language

```
plain text
no highlighting
no judgement
```

### Indented code block (4-space)

    let unhighlighted = "you can still write code this way"
    let nobody = "does though"

### Code block containing Markdown (must NOT render the inner Markdown)

```markdown
# This heading should appear as literal text

- This list item too
- **including** the asterisks

> And the blockquote marker, raw.
```

---

## 8. Tables

### Plain table

| Feature | Supported? | Notes |
| --- | --- | --- |
| Headings | yes | h1 through h6 |
| Tables | yes | this very one |
| Spinning anime intros | no | out of scope |

### Aligned columns

| Left-aligned | Centred | Right-aligned |
| :--- | :---: | ---: |
| `a`  | `b`     |   `c` |
| one  | two     | three |
| four | 5       |     6 |

### Inline formatting inside cells

| Style | Example | Renders as |
| :--- | :--- | :--- |
| Bold | `**bold**` | **bold** |
| Italic | `*italic*` | *italic* |
| Code | `` `code` `` | `code` |
| Link | `[home](https://example.com)` | [home](https://example.com) |
| Strikethrough | `~~old~~` | ~~old~~ |

### Slightly horrible table, because reality

| Column with a really wide header that pushes the table sideways | Short | Medium |
| --- | --- | --- |
| short cell | this cell wraps onto multiple visual lines if the renderer is doing its job | middling |
| `code()` | text | text |

---

## 9. Thematic breaks

Three or more hyphens:

---

Three or more asterisks:

***

Three or more underscores:

___

(All three should render as the same horizontal rule.)

---

## 10. Images

### Sibling PNG (relative path)

![App icon](media/quick-markdown.png "The Quick Markdown app icon")

### Sibling SVG (relative path)

![Generated logo banner](media/qm-logo.svg "Hand-rolled SVG, rasterised via WebKit")

### Remote image (URL)

![GitHub Octocat](https://github.githubassets.com/images/modules/logos_page/Octocat.png)

### Image inside a link (click-through)

[![App icon, but clickable](media/quick-markdown.png)](https://github.com/Zesty0wl/quick-markdown)

### Image with no alt text

![](media/quick-markdown.png)

### Image that doesn't exist (should show a placeholder, not crash)

![A figment of the imagination](media/this-file-does-not-exist.png)

---

## 11. Footnotes

This is a sentence with a footnote.[^one] Here is another one,[^two] and a
third with a longer name.[^the-third-footnote]

[^one]: A simple, one-line footnote.

[^two]: A footnote with **bold**, *italic*, and `code` inside it.

[^the-third-footnote]: A footnote with multiple paragraphs.

    This second paragraph belongs to the same footnote because it's
    indented four spaces.

    And a list, for good measure:

    - one
    - two
    - three

---

## 12. HTML pass-through

Inline HTML — shown dimmed in the editor, **not** rendered as live HTML
(because we are a Markdown editor, not a browser):

This sentence has <span style="color: red">a span tag</span> in it.

Block HTML:

<div class="note">
  <p>This is a raw HTML block. The renderer should display the tags as
  literal, dimmed text rather than executing them.</p>
</div>

HTML entities should pass through as their decoded characters:
&copy; 2026, &amp; friends, &mdash; long dash, &nbsp;non-breaking space.

---

## 13. Unicode and friends

| Category | Sample |
| :--- | :--- |
| Emoji | 🎉 🚀 🐢 📝 🍕 |
| Combining marks | café, naïve, résumé |
| CJK | 你好世界 こんにちは 안녕하세요 |
| Cyrillic | Здравствуй, мир |
| Greek | Γειά σου, κόσμε |
| RTL (Arabic) | مرحبا بالعالم |
| RTL (Hebrew) | שלום עולם |
| Symbols | ∑ ∫ √ ≠ ≈ ∞ ← ↔ → ⇒ ⇔ |

A line with mixed direction text: This is English, then **مرحبا**, then
back to English. The whole line should still be selectable in a sensible
order.

---

## 14. Stress tests

### Long single word (should not break the layout)

supercalifragilisticexpialidocioussupercalifragilisticexpialidocioussupercalifragilisticexpialidocious

### Lots of inline `code` in one paragraph

You can chain `git status` and `git diff` and `git add -p` and `git commit`
and `git push` and `git log --oneline --graph --decorate --all` and
`git rebase -i HEAD~3` and `git reflog` until something either works or
becomes unrecoverable.

### Many emphasis runs

**a** **b** **c** **d** **e** **f** **g** **h** **i** **j** **k** **l**
**m** **n** **o** **p** **q** **r** **s** **t** **u** **v** **w** **x**
**y** **z**

### A deeply nested list

- L1
  - L2
    - L3
      - L4
        - L5
          - L6 (at which point you have probably lost the plot)

---

## 15. The empty section

(Renderers should handle this header followed by nothing without crashing.)

###

(And a heading with no text, immediately followed by another section.)

## 16. End

If you made it here, the editor probably works. Congratulations to both
of us.

If something on this page rendered wrong, the smallest possible repro
goes a long way: copy the offending block into a new file, [open an
issue][issues], paste the block, describe what you expected, and what
you got instead. The fix usually lives within ten lines of code of where
the bug lives.

Now go open one of *your* Markdown files. That's what this is all for.
