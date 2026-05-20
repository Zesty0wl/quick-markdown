<div align="center">

# Quick Markdown

**A focused, beautiful, native macOS Markdown editor for the AI era.**

[![Build](https://github.com/Zesty0wl/quick-markdown/actions/workflows/build.yml/badge.svg)](https://github.com/Zesty0wl/quick-markdown/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-blue.svg)](#system-requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)

<img src="quick-markdown.png" alt="Quick Markdown" width="640">

</div>

---

Quick Markdown opens a `.md` file. It makes it beautiful. It gets out of the way.

It's built for the files AI assistants produce — READMEs, documentation, meeting notes, long-form drafts — and does three things exceptionally well:

1. **Watch** a Markdown file change as an LLM (Claude Code, Copilot, etc.) writes it, and render the updates live.
2. **Edit** Markdown with a hybrid live-preview editor that looks rendered but stores plain Markdown.
3. **Share** the result by exporting to PDF or copying as rich text into Outlook, Word, or Notion.

It is *not* a knowledge base, a vault, or a workspace. One file at a time. Source is the truth.

---

## Features

- **Hybrid live preview** — rendered headings, bold, lists, tables, code, with raw markers revealed near the cursor.
- **Plain source mode** with VS Code Dark+ / Light+ style syntax highlighting, monospaced font, fluid toggle.
- **Live file watching** — external writes (e.g. an LLM writing to the file) are reflected within ~150 ms, with a non-modal banner if you also have unsaved local edits.
- **Format menu** with the keyboard shortcuts you'd expect: Bold, Italic, Code, Link, Heading 1–3, Insert Code Block, Insert Table, Toggle Task.
- **Copy Formatted** (⇧⌘C) writes HTML + RTF + plain Markdown to the pasteboard — pastes cleanly into Outlook for Mac, Word, and Notion.
- **PDF export** via `WKWebView.createPDF` — single tall page, fit for sharing.
- **Reading themes & fonts** — System, Sepia, Solarized, etc. + System / Serif / Rounded / Dyslexia-Friendly (with a one-click download link to [OpenDyslexic](https://opendyslexic.org) when the font isn't installed).
- **Read aloud** — built-in text-to-speech with source highlighting.
- **GFM tables, task lists, code fences, footnotes, YAML front matter, strikethrough, images** (external URLs + relative paths, including SVG).
- **Sandboxed.** App Sandbox, hardened runtime, sandboxed scripting; safe to ship through the Mac App Store.
- **Native.** Pure Swift 6 / AppKit. No Electron. No web runtime in the editor (only used for HTML rendering and PDF export).

---

## System requirements

- macOS 26.0 (Tahoe) or newer
- Apple Silicon or Intel
- Xcode 26.0 or newer (only to build from source)

---

## Install

### Download a release

Download the latest signed and notarized installer package from:

- https://github.com/Zesty0wl/quick-markdown/releases/latest

### Build from source

```bash
# Prereqs: Xcode 26+ and (optionally) xcodegen
brew install xcodegen          # only needed if you edit project.yml

# Clone
git clone https://github.com/Zesty0wl/quick-markdown.git
cd quick-markdown

# (Optional) re-generate the .xcodeproj from project.yml
xcodegen generate

# Build the Debug app
xcodebuild -scheme QuickMarkdown -configuration Debug build

# Open in Xcode and run
open QuickMarkdown.xcodeproj
```

The first build pulls [`swift-markdown`](https://github.com/apple/swift-markdown) via Swift Package Manager.

Maintainers: see [`RELEASING.md`](RELEASING.md) for the release workflow.

### Code signing for local builds

`project.yml` ships with `DEVELOPMENT_TEAM: ""` and `CODE_SIGN_IDENTITY: "-"` so the project builds with ad-hoc signing out of the box. To run a sandboxed build under your own team:

1. Open the project in Xcode.
2. Select the `Quick Markdown` target → **Signing & Capabilities** → set your Team.
3. Build & run.

Don't commit your team ID — local Xcode changes to `project.pbxproj` are easy to do by accident. If you regenerate via `xcodegen generate`, your `project.yml` override (e.g. `DEVELOPMENT_TEAM: ABCDE12345`) stays in your working tree.

---

## How it works

| Concern | Implementation |
|---|---|
| Markdown parsing | [`swift-markdown`](https://github.com/apple/swift-markdown) (Apple, SPM) |
| Editor | `NSTextView` + an `NSTextStorage` subclass that stores the raw Markdown source and applies display attributes only (`MarkdownTextStorage`) |
| Live preview rendering | AST walk produces `NSAttributedString` styling (`MarkdownAttributedRenderer`, `LivePreviewStyler`) |
| Source-mode highlighting | Regex-based attribute pass with a VS Code-matched palette (`PlainSourceHighlighter`) |
| HTML / PDF export | Custom `HTMLRenderer` + offscreen `WKWebView.createPDF` |
| Rich-text clipboard | Composite `NSPasteboardItem` with `public.html`, `public.rtf`, `public.utf8-plain-text` (`FormattedPasteboardWriter`) |
| File watching | `NSFilePresenter` on the document, debounced 150 ms |
| Project generation | [`xcodegen`](https://github.com/yonaskolb/XcodeGen) from `project.yml` |

The full design rationale lives in [`QuickMarkdown_PRD.md`](QuickMarkdown_PRD.md).

---

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Open file | ⌘O |
| New file | ⌘N |
| Save | ⌘S |
| Save As… | ⇧⌘S |
| Toggle Preview / Source | ⇧⌘P |
| Copy Formatted | ⇧⌘C |
| Export PDF | ⇧⌘E |
| Bold | ⌘B |
| Italic | ⌘I |
| Inline code | ⌘E |
| Link | ⌘K |
| Insert Code Block | ⇧⌘K |
| Insert Table | ⌥⌘T |
| Toggle Task | ⇧⌘T |
| Heading 1 / 2 / 3 | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 |

---

## Project layout

```
QuickMarkdown/
├── App/                  # AppDelegate, MainMenuBuilder, main.swift, onboarding
├── Document/             # NSDocument subclass, window controller, status bar
├── Editor/               # NSTextView, NSTextStorage, styling, speech, themes
├── Export/               # HTMLRenderer, PDFExporter, RTFRenderer, pasteboard writer
├── Assets.xcassets/      # App icon
├── Info.plist            # Generated by xcodegen — DO NOT edit by hand
├── PrivacyInfo.xcprivacy # App Store privacy manifest
└── QuickMarkdown.entitlements # Generated — edit project.yml instead

project.yml               # xcodegen spec — source of truth for the project
QuickMarkdown_PRD.md      # Product requirements & design rationale
```

---

## Contributing

Pull requests are welcome. Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for the design philosophy ("does this make the app better at opening one Markdown file?") and the code style.

By contributing you agree your code is licensed under the MIT License and that you abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Security

Found a vulnerability? Please **do not** file a public issue — see [`SECURITY.md`](SECURITY.md) for private disclosure instructions.

---

## License

[MIT](LICENSE) © 2026 Neil Johnson

Built with [`swift-markdown`](https://github.com/apple/swift-markdown) (Apache 2.0). OpenDyslexic font (when installed by the user) is © Abelardo Gonzalez under [SIL Open Font License 1.1](https://opendyslexic.org/about).
