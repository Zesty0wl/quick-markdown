# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog:
https://keepachangelog.com/en/1.1.0/

This project follows Semantic Versioning:
https://semver.org/spec/v2.0.0.html

## Unreleased

## 1.0.10 - 2026-10-28

### Added

- **Syntax-highlighted code blocks.** Fenced code blocks that name a
  language (` ```swift `, ` ```python `, …) are coloured in the Preview
  and in PDF export, using a bundled, offline copy of Highlight.js 11.12
  with GitHub light and dark themes. The Source view colours the same
  blocks. Unknown languages and unlabelled fences stay plain.
- **Equations.** `$…$` renders inline and `$$…$$` as a display block in
  the Preview and in PDF export, using a bundled, offline copy of KaTeX
  0.18.4. Dollars inside code, escaped `\$`, and prices such as
  `$5 and $10` or `$5/$10` stay as text. Copying an equation from the
  Preview pastes its TeX source. Copy Formatted keeps equations as TeX,
  because Word and Outlook can't display KaTeX's markup.
- **Mermaid diagrams.** ` ```mermaid ` blocks render as diagrams
  (flowcharts, sequence, state, class and the other Mermaid types) in the
  Preview, in light or dark to match the reading theme, and in PDF export,
  using a bundled, offline Mermaid 11.17.2 in strict security mode. A
  diagram with a syntax error keeps its source, with a note above it.
  The script is only loaded into pages that contain a diagram. See
  `test-files/03-mermaid.md`.

- **GitHub-style alerts.** `> [!NOTE]`, `[!TIP]`, `[!IMPORTANT]`,
  `[!WARNING]` and `[!CAUTION]` render as callouts with GitHub's colours
  and icons (lighter colours on dark themes) in the Preview and PDF, and
  as a coloured, titled block in Copy Formatted. As on GitHub, the marker
  must be alone on the quote's first line.

- **Full CommonMark and GitHub Flavored Markdown conformance.** The
  renderer now passes every example in the GFM spec (672), cmark-gfm's
  extension tests (30) and CommonMark 0.31.2 (652), apart from documented
  places where it deliberately does what GitHub does. A new unit-test
  target renders the suites, and `scripts/spec-report.py` compares the
  results (`--check` for CI).
- **Bare URLs and email addresses become links** (`www.example.com`,
  `https://…`, `name@example.com`, `mailto:` and `xmpp:`), with GitHub's
  rules for trailing punctuation and brackets.
- **Footnotes use GitHub's structure**: a footnotes section with a proper
  list, so a footnote can hold several paragraphs, quotes, lists and code;
  label-based anchors; one back-link per reference.

- **Popular Markdown extensions** beyond GitHub's:
  - Obsidian-style callouts: custom titles (`> [!tip] Title`), Obsidian's
    types (info, todo, success, question, failure, danger, bug, example,
    quote, …) and foldable callouts (`[!tip]-` closed, `[!tip]+` open).
  - Maths in every common syntax: GitHub's ```` ```math ```` blocks and
    `` $`…`$ ``, and LaTeX `\(…\)` / `\[…\]` (common in LLM output).
  - Emoji shortcodes (`:tada:`) from GitHub's own list.
  - `==highlight==`, `^[inline footnotes]`, abbreviations
    (`*[HTML]: …`), definition lists (`Term` / `: definition`).
  - Wiki links: `[[Page]]`, `[[Page|Alias]]`, `[[Page#Heading]]`, and
    `![[image.png|200]]` embeds.
  - `[TOC]` / `[[_TOC_]]` table of contents, and custom heading ids
    (`## Title {#id}`).
  - YAML front matter is shown as a table at the top of the Preview, as
    GitHub does, instead of being hidden.
  - GitHub's `#gh-dark-mode-only` / `#gh-light-mode-only` images, and
    `<picture>` sources that follow the reading theme.
  - Syntax highlighting for all 193 Highlight.js languages (was 36),
    including Dockerfile, PowerShell, TOML, Haskell, Scala, Elixir and
    LaTeX.
  See `test-files/04-extensions.md` for a tour.

### Changed

- **No smart punctuation**, as on GitHub: quotes stay straight and `--`
  stays two hyphens, so command-line flags in prose survive.
- **Scripts in a document no longer run in the Preview.** GitHub's tag
  filter shows `<script>`, `<style>`, `<iframe>`, `<textarea>` and similar
  tags as text, a Content Security Policy blocks event-handler attributes
  and `javascript:` links, and `javascript:`/`vbscript:` link targets are
  removed.

### Fixed

- **Tight lists render tight.** List items were always wrapped in
  paragraphs, so every list looked double-spaced.
- **Ordered lists keep their starting number** (`3.` starts at 3).
- **Table column alignment** (`:---:`, `---:`) now shows in the Preview.
- **Image alt text** with formatting or links no longer breaks the image.
- **Link and image URLs** with spaces, accents or brackets are encoded
  correctly.
- **Code fence languages** use the first word of the info string
  (` ```ruby startline=3 ` is Ruby).
- **Heading anchors keep non-ASCII letters** (`## Café` is `#café`;
  headings in other scripts get anchors at all).
- **A document starting with a `---` rule** no longer loses everything up
  to the next `---` (only YAML-looking blocks count as front matter).
- **The view no longer jumps while another app or an agent edits the
  file.** The Preview now updates in place instead of reloading: nothing
  flashes, the block at the top of the window stays where it is when text
  changes above or below it, and a reader at the bottom follows text added
  there. Mermaid diagrams are drawn before the swap. The Source view
  replaces only the changed text and keeps the top visible line in place,
  and the caret moves with the text around it. Outside saves also no
  longer trigger a second, full reload: the folder watcher meant for
  images now ignores the document's own file and its atomic-save
  temporaries.
- **Duplicate headings get distinct link anchors.** A second "Notes"
  heading is now `#notes-1`, as on GitHub, so links to it no longer jump
  to the first one.
- **Copy Formatted includes relative images.** Images such as
  `![](media/photo.png)` are now resolved against the document's folder,
  so they come through in the pasted copy.
- **PDF export no longer clips the last line.** The page height was
  measured from `<body>`, which leaves out the first heading's collapsed
  top margin, so the final ~24 px of longer documents was cut off.
- **Safer SVG images.** SVGs embedded in a document are now rendered with
  scripts disabled, no network or file access, no navigation, a 25 MB
  file limit, and at most 2048 points on the longest side.
- Bumped `MARKETING_VERSION` to 1.0.10 and `CURRENT_PROJECT_VERSION` to 12.

## 1.0.9 - 2026-09-04

### Fixed

- **Copying from the Preview no longer carries the theme's colours into
  the pasteboard.** WebKit's default copy serialises the computed style of
  every element, so each paragraph landed in Mail / Outlook / Word with an
  inline `color` and an opaque `background-color` taken from the preview
  theme. That was invisible in a light compose window but rendered every
  paragraph as a grey box in dark mode — for the sender and for anyone
  reading the message in a dark-mode client. The preview now intercepts
  `copy`, strips preview-only attributes from the selection, and hands the
  clean semantic HTML to Swift, which writes it to the pasteboard (with
  plain text) wrapped in a colour-free font/size declaration so the
  receiving app's own theme applies. Written from Swift deliberately:
  HTML set via `clipboardData` from JavaScript goes through WebKit's
  sanitiser, which re-inlines the computed `color`.
- Bumped `MARKETING_VERSION` to 1.0.9 and `CURRENT_PROJECT_VERSION` to 11.

## 1.0.8 - 2026-05-31

### Fixed

- **File ▸ Print… no longer prints blank pages or silently drops the
  job.** The menu item was wired to `NSView.printView(_:)`, which
  walked the responder chain to either the editor's `NSTextView`
  (configured with `allowsNonContiguousLayout = true` and an
  effectively infinite container height, so pagination began before
  layout existed) or the preview's `WKWebView` (no useful
  `printView:` implementation) — both produced empty pages. Print
  now routes through a new `DocumentWindowController.printDocument(_:)`
  that reuses the same paginated HTML → WebKit → PDF pipeline as
  *Export as PDF* and hands the result to `NSPrintOperation` via
  `PDFDocument`.
- The print operation now retains its backing `PDFDocument` and the
  `NSPrintOperation` itself for the lifetime of the sheet-modal
  session. `runModal(for:delegate:didRun:contextInfo:)` is
  asynchronous, and without the retain the `PDFDocument` was being
  released the instant the helper returned. CUPS then spooled a
  "successful" empty job and no paper came out of the printer. The
  references are cleared in a `printOperationDidRun(_:success:contextInfo:)`
  callback.
- Bumped `MARKETING_VERSION` to 1.0.8 and `CURRENT_PROJECT_VERSION`
  to 10.

## 1.0.7 - 2026-05-25

### Changed

- Quick Markdown now ships as a **universal binary** (Apple Silicon
  and Intel) and the minimum supported macOS is lowered from
  **26 Tahoe** to **15 Sequoia**. The deployment target was dropped
  from `26.0` to `15.0` in `project.yml` (top-level + target +
  `MACOSX_DEPLOYMENT_TARGET`), `ARCHS` is pinned to
  `$(ARCHS_STANDARD)` (which is `arm64 x86_64` on macOS), and
  `ONLY_ACTIVE_ARCH` is forced `NO` for the Release configuration so
  archives always emit both slices. The CI workflow no longer gates
  the build on `macosx26` SDK availability and now passes
  `ONLY_ACTIVE_ARCH=NO ARCHS='arm64 x86_64'` explicitly. Verified by
  `lipo -info` on the produced binary.
- Bumped `MARKETING_VERSION` to 1.0.7 and `CURRENT_PROJECT_VERSION`
  to 9.

## 1.0.6 - 2026-05-24

### Fixed

- In-document anchor links in the rendered preview (e.g. a
  `[Jump to Part 6.5](#part-65--sync-an-out-of-date-fork)` link) now
  scroll the preview to the matching heading instead of silently
  doing nothing. `HTMLRenderer` now stamps every heading with a
  GitHub-flavour slug `id` (lowercase, non-alphanumerics stripped,
  spaces to hyphens) so WKWebView has something to scroll to when
  the fragment URL resolves.
- Relative `file://` links in the rendered preview (e.g.
  `../../GLOSSARY.md`) that resolve to a path which doesn't exist on
  disk now beep, reveal the nearest existing ancestor folder in
  Finder, and log the missing path via `NSLog` so the failure is
  visible. Previously `NSWorkspace.shared.open` was called with no
  feedback and the click appeared dead. Valid relative links still
  open as before.

## 1.0.5 - 2026-05-22

### Fixed

- External links in the rendered preview (Preview mode) now open in the
  user's default browser instead of either silently doing nothing or
  loading the remote page inside the Quick Markdown preview pane.
  On the macOS 26 SDK the `WKNavigationDelegate.decidePolicyFor` method's
  `decisionHandler` parameter is declared `@escaping @MainActor (...)`
  and our implementation was missing the `@MainActor` annotation. Swift
  treated the method as "nearly matching" the protocol but didn't bind
  it to the protocol slot, so WebKit's default "allow every navigation
  in-frame" policy ran and our route-to-system-browser code was never
  reached. The signature is now exact, and every external scheme
  (`http`, `https`, `mailto`, `tel`, `sms`) is handed to
  `NSWorkspace.shared.open`. Same-page fragment scrolling (footnote
  references, TOC anchors) still works inside the preview.
- `target="_blank"` and `window.open(...)` style links are now also
  caught via the `WKUIDelegate.createWebViewWith` callback (WebKit asks
  the UI delegate for those *instead of* the navigation delegate) and
  routed to the system browser.

### Changed

- Bumped `MARKETING_VERSION` to 1.0.5 and `CURRENT_PROJECT_VERSION` to 7.

## 1.0.4 - 2026-05-21

### Added

- Autosave on by default. `autosavesInPlace` continuously writes edits to
  saved Markdown files in the background; `autosavesDrafts` persists
  never-saved Untitled windows into the app's per-container
  `Autosave Information/` folder. Quitting the app (including from the
  installer's postinstall script during an upgrade) no longer prompts to
  save and no longer loses unsaved content.
- Draft restoration on launch. Untitled documents that had real content
  when the app last quit reappear on next launch. Empty / whitespace-only
  drafts are dropped and the leftover autosave file is cleaned up, so
  ghost Untitled windows from older bugs don't keep haunting the user.

### Fixed

- Loose GFM task-list items (`- [ ]` followed by a blank line and more
  indented content like a code block or a second paragraph) now render
  with the checkbox on the same baseline as the item title, matching
  GitHub. Previously the checkbox sat on its own row above the title
  because swift-markdown wraps each item's first line in a `Paragraph`,
  and `<input type="checkbox">` followed by a block-level `<p>` broke
  onto two lines. The HTML renderer now unwraps the leading paragraph of
  every task-list item, not just tight ones.
- Code blocks in the live preview wrap long lines inside the box
  instead of forcing a horizontal scrollbar. Helps two cases at once:
  (a) over-indented list-item continuation paragraphs that CommonMark
  correctly classifies as indented code blocks (the common author
  mistake of aligning continuation under bold title text with 6 spaces
  instead of 2), and (b) genuine code blocks with very long lines (long
  shell pipelines, long URLs). The export pipeline is unchanged — code
  pasted into Word / Outlook / PDF still has strict `<pre>` semantics.

### Changed

- Installer postinstall script: the graceful-quit grace window grew from
  8 to 20 seconds so save-changes dialogs from older builds (1.0.3 or
  earlier) have time to be dismissed by a human before the force-kill
  fallback fires.
- Bumped `MARKETING_VERSION` to 1.0.4 and `CURRENT_PROJECT_VERSION` to 6.

## 1.0.3 - 2026-05-21

### Added

- Word/Pages-style table grid picker. `Insert Table…` (`⌥⌘T` or the new
  toolbar button) opens an 8×8 hover grid; click to commit. The new table
  lands at the caret with the first header cell selected.
- Cell-aware Tab / Shift-Tab / Return navigation in Markdown tables.
  Tab on the last cell appends a new row and re-aligns the pipes.
- `Realign Tables` (`⌃⌥⌘T`) pretty-prints every table in the document so
  the pipes line up by column. Alignment markers are preserved.
- `Insert Table` toolbar button (`tablecells` SF Symbol).
- FSEvents-based `MediaWatcher` re-renders the preview when a sibling
  image (PNG / SVG / JPEG) is updated by an external editor.

### Fixed

- Images with percent-encoded characters in their paths (for example
  `media/night%20sky.png`) now load correctly. The encoding pipeline
  decodes-then-re-encodes rather than double-encoding.
- Inline images (GitHub-style status badges) flow horizontally in the
  live preview instead of stacking onto their own lines.

### Changed

- README rewritten as a personal-tool sales sheet with screenshots, a
  theme gallery, and an updated keyboard cheat sheet.
- New `test-files/` demo corpus exercising every supported block,
  inline, and image case.
- Bumped `MARKETING_VERSION` to 1.0.3 and `CURRENT_PROJECT_VERSION` to 4.

## 1.0.2 - 2026-05-20

### Added

- In-app update notifier: on launch (once per 24 hours) and via the new
  "Check for Updates\u2026" menu item, the app polls the GitHub Releases
  API and offers a download link when a newer version is available.
  Sandbox-safe; uses only the existing `network.client` entitlement.

### Changed

- Bumped `MARKETING_VERSION` to 1.0.2 and `CURRENT_PROJECT_VERSION` to 3.

## 1.0.1 - 2026-05-20

### Added

- Signed and notarized macOS installer package (`.pkg`) for GitHub releases.
- Open-source repository scaffolding for community health, contribution
    workflows, and CI.

## 1.0.0 - 2026-05-20

### Added

- Initial public release of Quick Markdown.
