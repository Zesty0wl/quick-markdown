# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog:
https://keepachangelog.com/en/1.1.0/

This project follows Semantic Versioning:
https://semver.org/spec/v2.0.0.html

## Unreleased

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
