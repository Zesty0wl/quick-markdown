---
title: Extensions tour
author: Quick Markdown
tags:
  - github
  - obsidian
---

# Extensions tour {#tour}

[TOC]

## Callouts

> [!NOTE]
> GitHub alert: the marker alone on the first line.

> [!tip] Obsidian-style title
> Text after the marker becomes the title.

> [!warning]- Folded callout (click to open)
> Hidden until you open it.

> [!quote] Ada Lovelace
> That brain of mine is something more than merely mortal.

## Maths

Inline $E = mc^2$, GitHub's $`\sqrt{2}`$ form, and LaTeX \(a^2 + b^2 = c^2\).

```math
\int_0^1 x^2 \, dx = \frac{1}{3}
```

\[
\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
\]

## Inline extras

Emoji :tada: :rocket: :+1:, ==highlighted text==, an inline footnote^[Pandoc and Obsidian style.] and HTML written by the W3C.

*[HTML]: HyperText Markup Language
*[W3C]: World Wide Web Consortium

## Definition lists

Markdown
: A lightweight markup language.

CommonMark
: A strongly specified version of Markdown.
: Also a test suite.

## Wiki links

[[01-welcome]], [[02-the-kitchen-sink|the kitchen sink]] and [[01-welcome#Welcome]].

## Code in every language

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache curl
```

```powershell
Get-ChildItem -Path . -Filter *.md | Measure-Object
```

```haskell
main = putStrLn "Hello"
```

## Light and dark images

![Shown on light themes](media/quick-markdown.png#gh-light-mode-only)
![Shown on dark themes](media/qm-logo.svg#gh-dark-mode-only)
