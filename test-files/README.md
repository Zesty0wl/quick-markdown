# Quick Markdown Test Files

> A small, opinionated corpus of Markdown that exercises every block, inline,
> image, and edge case Quick Markdown is supposed to handle. Also the friendliest
> README in the building.

This folder is the **demo set**. Open any file here in Quick Markdown and you
should see things that look approximately as nice as they read.

## What's in here

| File | What it tests | Tone |
| :--- | :--- | :--- |
| [`01-welcome.md`](01-welcome.md) | The pitch, the PNG logo, the generated SVG, a handful of formatting flourishes. Start here. | Whimsical |
| [`02-the-kitchen-sink.md`](02-the-kitchen-sink.md) | Every block type, every inline style, lists, tables, code fences, footnotes, task lists, blockquotes, YAML front matter, HTML pass-through, weird Unicode, the lot. | Encyclopaedic |
| [`media/quick-markdown.png`](media/quick-markdown.png) | The app icon (1024×1024 PNG). Used inline in `01-welcome.md`. | Pixels |
| [`media/qm-logo.svg`](media/qm-logo.svg) | A hand-rolled SVG banner that should also render inline (via the in-app SVG rasteriser). | Vectors |

## How to use

```bash
# Easiest: just open one
open '01-welcome.md'

# Or, if Quick Markdown is the default for .md:
open .
```

You can also drag any of these files onto the Quick Markdown app icon, or use
**File → Open…** (⌘O). They're plain UTF-8 Markdown — nothing magic.

## What "works" should look like

- The PNG and SVG appear **inline**, sized to the editor width, not as broken
  `[Image: alt-text]` placeholders. If you see placeholders, something has eaten
  the sandbox file-read permission — see the README in the parent directory.
- Headings are real headings (big, semi-bold, with breathing room). The raw
  `#` markers should be **dimmed but still present** in the editor view, and
  **absent** when you copy/export.
- Tables render as actual tables, not as a pipe-and-dash ASCII smear.
- Code fences pick up syntax highlighting where a language is declared.
- The SVG is crisp at 2× scale (we render it through WebKit, not CoreSVG, on
  purpose — long story, short fix).

## Adding your own test cases

Stash new `.md` files alongside the existing ones and reference any sibling
images via `media/whatever.png`. The whole folder lives under `~`, so the
sandboxed app has read access — no extra entitlement dance.

If you find a Markdown construct the editor renders badly, add a minimal
repro here and open an issue. New ammunition is welcome.
