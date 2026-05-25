# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog:
https://keepachangelog.com/en/1.1.0/

This project follows Semantic Versioning:
https://semver.org/spec/v2.0.0.html

## Unreleased

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
