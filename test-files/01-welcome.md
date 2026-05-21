---
title: Quick Markdown
subtitle: There are many like it, but this one is mine.
author: The Maintainer
date: 2026-05-21
tags: [welcome, demo]
---

![Quick Markdown — there are many like it, but this one is mine](media/qm-logo.svg)

# Quick Markdown

> *A native, single-document Markdown editor for the AI era.*

You opened a file. The preview is **live** — when your LLM rewrites it on
disk, this window updates immediately. Hit `⇧⌘C` and the rich-text version
pastes cleanly into **Mail**, **Outlook**, **Word**, and **Notion**.
That's the whole pitch.

## What it does

| Feature | Shortcut | Notes |
| :--- | :---: | :--- |
| Live preview as the file changes | — | `tail -f`, but for prose |
| Toggle source ⇆ preview | `⌘⇧S` | Scroll position survives |
| Copy as rich text | `⇧⌘C` | Word, Outlook, Notion — all fine |
| Read aloud | `⌥⌘R` | The good Apple voices |
| Export to PDF | `⌘P` | Print-ready, paginated |

## Try it now

- [x] Open this file in Quick Markdown
- [x] Notice the SVG banner above renders crisply at any zoom
- [ ] **Click this checkbox** — it flips in both preview *and* source
- [ ] Press `⌘⇧S` to flip to the raw source view
- [ ] Press `⇧⌘C`, then paste into Mail — formatting survives the trip
- [ ] Drag another `.md` file onto this window to open it in a new one

```swift
// The shortest interesting program in any language.
import Foundation

let pitch = "Open the file. Look at it. Maybe edit it. Move on."
print(pitch)
```

## What it isn't

A vault. A plugin marketplace. A collaboration platform. A note-taking
app. There are forty-seven of those already installed on your machine.[^count]
Quick Markdown does three things — **watch**, **edit**, **share** — and
ignores the other seventeen.

## A small demonstration of the inline cast

Here is a paragraph with **bold**, *italic*, ***both at once***, some
`inline code()`, ~~text that didn't make the final cut~~, and a
[link to the repo](https://github.com/Zesty0wl/quick-markdown). The
formatter shortcuts (`⌘B`, `⌘I`, `⌘E`) are already in your fingers.

> "The best Markdown editor is the one you already have open."
> — A person who has never met a developer

---

When you're done here, [`02-the-kitchen-sink.md`](02-the-kitchen-sink.md)
exercises every block and inline construct the renderer is supposed to
handle, all in one file.

[^count]: This number is made up. The real number is probably higher,
    but no-one has the energy to count.
