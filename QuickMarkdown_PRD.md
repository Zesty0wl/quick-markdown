# Product Requirements Document
# Quick Markdown — macOS Native Markdown Editor

**Bundle ID:** com.neiljohn.quickmarkdown
**Platform:** macOS 26.0+
**Distribution:** Mac App Store (Sandboxed)
**Version:** 1.0
**PRD Revision:** 2.0 — 20 May 2026

---

## 1. Vision

Quick Markdown is a focused, beautiful native macOS app for opening, reading, and editing single Markdown files. It is designed as a companion tool for the files that AI assistants produce — READMEs, documentation, meeting notes, and long-form content — making them easy to read, edit, and share in polished form.

It does three jobs exceptionally well:

1. **Watch** a Markdown file change as an LLM (Claude Code, Copilot, etc.) writes it, and render the updates live.
2. **Edit** Markdown with a hybrid live-preview editor that looks rendered but stores plain Markdown.
3. **Share** the result by exporting to PDF or copying as rich text into Outlook, Word, or Notion.

It is not a knowledge base, not a vault, not a workspace. It opens a file. It makes it beautiful. It gets out of the way.

---

## 2. Core Principles

- **One file at a time.** No sidebar, no file tree, no project concept.
- **Source is the truth.** The buffer is always plain Markdown. Visual rendering is display-only attributes layered on top.
- **Gorgeous by default.** Typography, spacing, and colour must be best-in-class.
- **Share-ready output.** Formatted text must paste cleanly into Outlook, Word, and Notion.
- **Live by default.** External writes to the open file are reflected immediately.
- **Zero friction.** Open from Finder, edit, copy, export, close. No accounts, no syncing, no onboarding.

---

## 3. Target User

A technical professional (developer, engineer, product manager) who regularly receives or produces `.md` files from AI tools, coding assistants, or documentation workflows. They are comfortable with Markdown syntax but want a rendered view by default. They frequently need to paste formatted content into email clients or Word documents.

---

## 4. Feature Scope (v1.0)

### 4.1 In Scope

- Hybrid live-preview editor — rendered headings, bold, lists, tables, code, with raw markers revealed near the cursor
- Plain Source toggle — uniformly monospaced raw view for power use
- Live file watching — external writes to the open file reflected within ~150ms
- Format menu with keyboard shortcuts: Bold, Italic, Code, Link, Insert Table, Insert Code Block
- Rich text copy to clipboard (HTML + RTF, compatible with Outlook and Word)
- PDF export (single tall page via `WKWebView.createPDF`)
- "Open With > Quick Markdown" in Finder via `CFBundleDocumentTypes` registration
- Drag-and-drop `.md` file onto app icon or window
- Open / Save / Save As via standard macOS file dialogs (classic save model — no autosave)
- Dark mode and light mode support (automatic, system-matched)
- macOS 26.0 design language (large type, generous whitespace, fluid transitions)

### 4.2 Out of Scope (v1.0)

- Multi-file tabs or project management
- Finder Sync Extension (dropped — relying on standard `Open With` registration instead)
- iCloud or cloud sync
- Collaboration or comments
- Plugin or extension system
- Image embedding (beyond rendering existing image references)
- Version history / Time Machine browsing
- Drag-cell table editor UI (tables are edited as Markdown text in v1)
- Autosave (classic explicit-save model)

---

## 5. Supported Markdown Elements

CommonMark plus GFM extensions:

| Element | Requirement |
|---|---|
| Headings H1-H6 | Required |
| Bold, italic, strikethrough | Required |
| Inline code | Required |
| Code blocks (fenced, indented) | Required with syntax highlighting |
| Blockquotes | Required |
| Unordered and ordered lists | Required |
| Nested lists | Required |
| Horizontal rules | Required |
| Links (inline and reference) | Required — clickable in Live Preview mode |
| Images (external URL and relative path) | Required — render inline |
| Tables (GFM) | Required |
| Task lists (GFM `- [ ]`) | Required — clicking the rendered checkbox toggles the source character |
| Footnotes | Nice to have (defer if `swift-markdown` lacks support) |
| YAML front matter | Render as styled metadata block, not as raw YAML |

---

## 6. User Interface

### 6.1 Window

- Single-pane window. No sidebars.
- Minimum size: 700 x 500pt
- Default size: 900 x 680pt
- Centred on first launch, remembered thereafter via `NSUserDefaults`.
- Title bar: `<filename> — Quick Markdown`; with bullet dot (`<filename>• — Quick Markdown`) when unsaved.
- Toolbar (auto-hide, unified-compact style) contains only: View toggle (Preview / Source), Share button, Export PDF button.

### 6.2 Live Preview Editor (default view)

The editor is fundamentally an `NSTextView` backed by an `NSTextStorage` subclass that stores the **raw Markdown source**. After every edit, the storage re-parses the document (debounced ~50ms) and applies **display attributes only** — fonts, colours, paragraph spacing — to the existing characters. No characters are ever inserted or removed by the renderer. The user is always editing the source string.

Visual behaviour:

- Content area: centred column, max width 740pt, generous vertical padding.
- Font: System font (SF Pro Text / SF Pro Display scaled by heading level).
- H1: 32pt bold. H2: 24pt semibold. H3: 20pt semibold. Body: 16pt regular. Code: 14pt SF Mono.
- Line height: 1.6 body, 1.3 headings.
- **Marker reveal rule:** Markdown markers (`**`, `*`, `_`, `` ` ``, leading `#`, list bullets, link `[...](...)` syntax, table pipes) are visually dimmed to ~30% opacity when the cursor is not on or adjacent to them. When the cursor enters the line (or paragraph) containing markers, those markers fade to full opacity within 100ms. This is the "hybrid live preview" pattern (similar to Obsidian Live Preview, iA Writer hybrid mode).
- Code blocks: rounded rect container, subtle fill (`systemFill`), SF Mono 14pt, horizontal scroll.
- Blockquotes: left border accent bar (accent colour), 8pt left padding, italic body text.
- Tables: rendered as styled grid with alternating row fill. Underlying source is GFM pipe table. When cursor is in a table row, raw pipes are revealed.
- Task list items: leading `- [ ]` / `- [x]` is replaced visually with a native checkbox glyph; clicking the glyph flips the source character between `[ ]` and `[x]` and marks the document dirty.
- Links: rendered as underlined accent-colour text. The `[label](url)` syntax is hidden unless the cursor is on the link. Cmd+click opens the URL in the default browser.
- Images: render inline below the source line, max-width 100% of content column, centred. Source `![alt](path)` text remains visible (dimmed) above the rendered image.
- Horizontal rules: rendered as 1pt separator with 24pt vertical margin. Source `---` line is dimmed.
- YAML front matter: detected as `---`...`---` at document start; rendered as a styled metadata card (light background, smaller font, key-value rows). Raw text is hidden when cursor is outside; revealed when cursor enters.

### 6.3 Plain Source View

- Toggle via toolbar or `Cmd+Shift+P`.
- Same `NSTextView`, same buffer — but a global "uniform monospace" display mode that suppresses ALL rendering attributes and shows plain SF Mono 14pt text with regex-based syntax colouring (headings, code, links).
- This is the same `NSTextStorage`; toggling does not re-parse or rebuild. It just switches the attribute layer.
- No line numbers for v1.

### 6.4 View Toggle Transition

- Smooth crossfade (0.2s ease-in-out) achieved by animating attribute changes — not by swapping view controllers.
- Cursor position is preserved exactly across toggles because the underlying text storage and selection are unchanged.

### 6.5 Empty State

When no file is open, show a centred drop zone:
- Large document icon (SF Symbol `doc.text`, 72pt)
- Primary label: "Drop a Markdown file here"
- Secondary label: "or press Cmd+O to open one"
- Subtle dashed rounded-rect border (1pt dashed, `NSColor.separatorColor`, cornerRadius 12)
- On drag-hover: fill with `controlAccentColor.withAlphaComponent(0.1)`

### 6.6 Live File Watching

When a document is open, the app monitors its file URL for external changes (typical use: an LLM is writing to it).

- Implementation: `NSFilePresenter` on `MarkdownDocument` (preferred — gives us coordinated reads). Fall back to `DispatchSource.makeFileSystemObjectSource` if needed for streaming writes that don't go through file coordination.
- External-write notifications are coalesced with a 150ms debounce.
- **No local edits + file changed:** reload silently. Preserve scroll position. If the user is scrolled within 50pt of the bottom, auto-scroll to the new bottom (follow-mode for `tail -f`-style LLM streaming).
- **Local edits present + file changed:** show a non-modal banner across the top of the window:
  > "This file was changed outside Quick Markdown." [Reload] [Keep my changes]
- Reload re-reads the file, replaces buffer contents, clears dirty state.
- Keep my changes dismisses the banner; next save will overwrite.

### 6.7 Format Menu

New top-level menu **Format**, with these items (all operate on the current selection, or insert at the cursor if no selection):

| Item | Shortcut | Behaviour |
|---|---|---|
| Bold | `Cmd+B` | Wrap selection in `**...**`; if already wrapped, unwrap |
| Italic | `Cmd+I` | Wrap selection in `*...*`; if already wrapped, unwrap |
| Code | `Cmd+E` | Wrap selection in `` `...` `` |
| Link | `Cmd+K` | Wrap selection as `[selection](url)`; place cursor inside `()` |
| Heading 1 / 2 / 3 | `Cmd+Opt+1/2/3` | Convert current line to `# ` / `## ` / `### ` |
| Insert Code Block | `Cmd+Shift+K` | Insert ```` ```\n\n``` ```` block; place cursor on middle line |
| Insert Table | `Cmd+Opt+T` | Insert a 2x2 template with placeholders |
| Toggle Task | `Cmd+Shift+T` | Toggle current line between `- [ ]` and `- [x]` |

---

## 7. Clipboard and Export

### 7.1 Copy Formatted

Menu item: **Edit > Copy Formatted** (`Cmd+Shift+C`).

Copies the full document (or current selection if non-empty) to the clipboard as:
- `public.html` — full HTML with inline CSS only (no `<style>` block, no external stylesheets).
- `public.rtf` — RTF equivalent for apps that prefer RTF.
- `public.utf8-plain-text` — plain Markdown source as fallback.

Code blocks in HTML output: `<pre><code>` with `font-family: monospace`, light background `#f5f5f5`, border `1px solid #e0e0e0`, padding `8px`, `border-radius: 4px`.

This is the single most important sharing workflow. Test extensively against Outlook for Mac and Microsoft Word.

### 7.2 Standard Copy (Cmd+C)

- In Live Preview view: copies selected attributed text (so paste into another rich-text app keeps formatting).
- In Plain Source view: copies raw Markdown text.

### 7.3 Export to PDF

- Toolbar button and **File > Export as PDF...** (`Cmd+Shift+E`).
- Renders full document HTML (via `HTMLRenderer`) into an offscreen `WKWebView`.
- Calls `WKWebView.createPDF(configuration:)` to produce a single tall PDF — **no pagination in v1**. Page width matches A4 (595pt) for sensible margins; height grows to fit the content.
- Save panel defaults to the same directory as the source `.md` file (security-scoped bookmark required).
- Filename defaults to `<source-filename>.pdf`.

Rationale for single-page: `WKPDFConfiguration` does not paginate, and `NSPrintOperation` with `WKWebView` is fiddly and produces inconsistent output. A single tall page is fit-for-purpose for sharing reviewable documents.

---

## 8. File Handling

- Supports opening `.md` and `.markdown` file extensions.
- Read and written as UTF-8.
- `NSDocument` subclass for dirty state, undo, and standard macOS document lifecycle.
- **Classic save model:** no autosave. `Cmd+S` saves; dirty dot appears in the title bar close button when there are unsaved changes; standard "Save changes?" sheet on close.
- Undo/redo: full `NSUndoManager` integration. Undo coalescing for typing as per `NSTextView` defaults.

### 8.1 New File

`File > New` (`Cmd+N`) opens an untitled document with placeholder content:

```
# Untitled

Start writing here.
```

### 8.2 Drag and Drop

- Window accepts drag of a single `.md` or `.markdown` file.
- Dock icon accepts drag (via `application(_:open:)`).
- If an unsaved document is open, prompt to save before replacing.

---

## 9. Finder Integration

No custom Finder extension. The standard macOS "Open With" submenu picks Quick Markdown up automatically once `CFBundleDocumentTypes` declares ownership of `.md` and `.markdown`.

`Info.plist` declares document types for `net.daringfireball.markdown` and `public.plain-text` with extensions `md` and `markdown`. The first time the app launches, macOS Launch Services indexes it and the user can right-click any `.md` file in Finder and choose **Open With > Quick Markdown**.

To make Quick Markdown the **default** opener, users right-click → Get Info → Open with → Quick Markdown → Change All. This is standard macOS behaviour; no extension required.

---

## 10. App Sandbox and Entitlements

Fully sandboxed; must pass Mac App Store review.

Required entitlements:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.files.user-selected.read-write</key>
<true/>
<key>com.apple.security.print</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

`network.client` is required because `WKWebView` (used for HTML rendering / PDF export) requires network entitlement even for in-memory HTML strings under sandbox.

Security-scoped bookmarks are used for files opened via `NSOpenPanel` so file watching can continue across launches.

---

## 11. Keyboard Shortcuts Reference

| Action | Shortcut |
|---|---|
| Open file | `Cmd+O` |
| New file | `Cmd+N` |
| Save | `Cmd+S` |
| Save As… | `Cmd+Shift+S` |
| Toggle Preview / Source | `Cmd+Shift+P` |
| Copy Formatted | `Cmd+Shift+C` |
| Export PDF | `Cmd+Shift+E` |
| Find | `Cmd+F` |
| Close window | `Cmd+W` |
| Undo / Redo | `Cmd+Z` / `Cmd+Shift+Z` |
| Bold | `Cmd+B` |
| Italic | `Cmd+I` |
| Code | `Cmd+E` |
| Link | `Cmd+K` |
| Insert Code Block | `Cmd+Shift+K` |
| Insert Table | `Cmd+Opt+T` |
| Toggle Task | `Cmd+Shift+T` |
| Heading 1 / 2 / 3 | `Cmd+Opt+1/2/3` |

---

## 12. Technology Stack

| Component | Technology |
|---|---|
| Language | Swift 6 (strict concurrency) |
| UI Framework | AppKit (NSDocument, NSTextView, NSToolbar) |
| Markdown Parsing | `swift-markdown` (Apple, SPM) |
| Text Rendering | `NSTextStorage` subclass with attribute-only updates |
| Plain Source Highlighting | Regex-based attribute pass, same storage |
| File Watching | `NSFilePresenter` (primary) + `DispatchSource` (fallback) |
| PDF Export | `WKWebView.createPDF(configuration:)` |
| HTML / RTF Rendering | Custom `HTMLRenderer` (AST walk) + `NSAttributedString.data(from:...)` |
| Clipboard | `NSPasteboard` with `public.html`, `public.rtf`, `public.utf8-plain-text` |
| Preferences | `UserDefaults` (no iCloud KVS) |
| Package Manager | Swift Package Manager |
| Minimum Deployment | macOS 26.0 |
| Project Generation | `xcodegen` from `project.yml` |

---

## 13. Build Phases

Each phase is independently testable. Build, validate, then proceed.

---

### Phase 1 — Project Scaffold and Document Architecture

**Goal:** Buildable Xcode project with correct bundle ID, sandbox, and a working `NSDocument` subclass that can open, display (as plain text), and save `.md` files.

**Tasks:**

1.1 Project layout under repo root:
- `project.yml` — xcodegen spec (single app target, no FinderSync target)
- `QuickMarkdown/` — source root
  - `App/AppDelegate.swift`, `App/Info.plist`
  - `Document/MarkdownDocument.swift`, `Document/DocumentWindowController.swift`
  - `QuickMarkdown.entitlements`
  - `Assets.xcassets/`

1.2 `project.yml` declares:
- Product name: `Quick Markdown`
- Bundle ID: `com.neiljohn.quickmarkdown`
- Deployment target: macOS 26.0
- Swift 6 strict concurrency
- App Sandbox + file-access + print + network.client entitlements
- `CFBundleDocumentTypes` for `net.daringfireball.markdown` + `public.plain-text` with extensions `md`, `markdown`
- SPM dependency: `swift-markdown` from `https://github.com/apple/swift-markdown`

1.3 `MarkdownDocument`:
- `NSDocument` subclass
- `content: String` property
- `read(from:ofType:)` → decode UTF-8
- `data(ofType:)` → encode UTF-8
- `autosavesInPlace` → `false` (classic save model)

1.4 `DocumentWindowController`:
- `NSWindowController` subclass
- Hosts a placeholder `NSTextView` showing `document.content`
- Default 900x680, min 700x500
- Window frame autosave name

1.5 `AppDelegate`:
- `applicationShouldHandleReopen` → standard
- `applicationShouldOpenUntitledFile` → `true` only if no document restored
- `applicationSupportsSecureRestorableState` → `true`

**Validation:**
- Project generates with `xcodegen` and builds with `xcodebuild` (zero warnings under `-warnings-as-errors`).
- App launches and shows an untitled window.
- Open a `.md` file via Finder Open With → text appears.
- Edits + `Cmd+S` save without error; dirty dot behaves.
- "Save changes?" sheet on close with unsaved edits.

---

### Phase 2 — Live Preview Editor (hybrid inline preview)

**Goal:** Replace the plain `NSTextView` with the hybrid live-preview editor. The buffer is always raw Markdown source; display attributes are applied on top, with marker-reveal-near-cursor behaviour.

**Tasks:**

2.1 Add `swift-markdown` SPM dependency.

2.2 `MarkdownStyles.swift` — single source of typography, colours, spacing, all using semantic `NSColor` values so light/dark mode just works.

2.3 `MarkdownTextStorage.swift`:
- `NSTextStorage` subclass holding an `NSMutableAttributedString` of the raw source.
- Implements the four required overrides: `string`, `attributes(at:effectiveRange:)`, `replaceCharacters(in:with:)`, `setAttributes(_:range:)`.
- On `processEditing()`, schedules an async (debounced 50ms) re-parse + restyle.
- Restyle pass: parse with `swift-markdown` (`Document(parsing: string)`), walk the AST, compute attribute ranges using each node's `range.lowerBound`/`upperBound` (source locations from `swift-markdown`), apply attributes inside `beginEditing()`/`endEditing()`.
- **Crucially:** restyle never inserts or removes characters; it only sets attributes.

2.4 Marker reveal:
- `MarkdownTextStorage` exposes a `cursorLocation: Int?` property.
- During styling, markers (`**`, `*`, `_`, `` ` ``, leading `#`, list bullets, link `[...]( )` syntax, table pipes, fence ` ``` `) get a "dimmed" attribute (`foregroundColor` with 30% alpha) by default.
- If `cursorLocation` falls within the paragraph containing the marker, the dimming is removed.
- `EditorViewController` listens to `selectionDidChange` and pushes new cursor location into storage, triggering a fast (style-only) restyle.

2.5 `EditorViewController.swift`:
- `NSViewController` hosting `NSScrollView` + `NSTextView`.
- `NSTextView` configured with the `MarkdownTextStorage` (use TextKit 1 path — TextKit 2 + custom `NSTextStorage` is supported but more constrained; TextKit 1 is the pragmatic choice).
- Centred content column (max width 740pt) achieved via `textContainerInset` and `textContainer.size`.
- Wires text changes back to `MarkdownDocument.content`.

2.6 Cmd-click on a link opens the URL via `NSWorkspace.shared.open`.

2.7 Task list checkbox interaction:
- Custom `NSTextAttachmentCell` (or hit-test on the rendered glyph) for `- [ ]` / `- [x]`.
- Click toggles the underlying character in source; document becomes dirty.

**Validation:**
- Open a complex `.md` file (headings, bold, lists, code, tables, links). Renders cleanly.
- Typing in a heading line keeps heading style.
- Cursor moving onto a `**bold**` span reveals the `**` markers; moving away dims them.
- Cmd+click on a link opens browser.
- Clicking a task checkbox toggles `- [ ]` ↔ `- [x]` and marks dirty.
- Dark mode toggle re-renders cleanly.
- No stutter on a 5,000-word document.

---

### Phase 2.5 — Live File Watching

**Goal:** External writes to the open file are reflected in the editor within ~150ms.

**Tasks:**

2.5.1 Conform `MarkdownDocument` to `NSFilePresenter`:
- `presentedItemURL` → document's file URL
- `presentedItemOperationQueue` → dedicated serial queue
- Register/unregister via `NSFileCoordinator.addFilePresenter` on open/close.

2.5.2 Implement `presentedItemDidChange()`:
- Debounce 150ms (cancel pending work; schedule new).
- Re-read file via `NSFileCoordinator(filePresenter: self).coordinate(readingItemAt:...)`.
- If `content` is unchanged → noop.
- If document has no unsaved edits → update `content` on main, preserve scroll position; if scrolled within 50pt of bottom, scroll to new bottom.
- If document has unsaved edits → post a notification; `DocumentWindowController` shows a reload banner.

2.5.3 Reload banner (`ReloadBannerView.swift`):
- Slide-down banner at top of editor.
- Two buttons: Reload, Keep my changes.
- Auto-dismisses if file reverts to match buffer.

2.5.4 Follow-mode helper:
- `isScrolledToBottom(threshold: 50)` on `NSScrollView`.
- After reload, if was-at-bottom, scroll to end.

**Validation:**
- Open `notes.md` in Quick Markdown.
- From terminal: `echo "# Hello" > notes.md` → editor updates within ~200ms.
- Append to file in a loop (`while true; do echo "line" >> notes.md; sleep 0.1; done`) — editor follows the tail without flicker.
- Make a local edit in Quick Markdown, then modify file externally → banner appears.
- Reload restores file contents; Keep my changes dismisses banner.

---

### Phase 3 — Plain Source Toggle

**Goal:** Toggle between Live Preview and Plain Source within the same editor.

**Tasks:**

3.1 Add `displayMode: DisplayMode` (`livePreview` / `plainSource`) to `MarkdownTextStorage`.

3.2 In `plainSource` mode:
- Skip the AST-walk style pass.
- Run a regex-based pass that applies only colour to: headings, links, inline code, fenced code blocks, blockquotes.
- All text is SF Mono 14pt.

3.3 Toggle method on `EditorViewController` that flips the mode and triggers a full restyle.

3.4 Toolbar item (`NSSegmentedControl`, two segments: Preview / Source) bound to the toggle.

3.5 `Cmd+Shift+P` shortcut wired via `View > Toggle Preview / Source` menu item.

**Validation:**
- Toggle preserves cursor position and selection.
- Toggle is visually crisp (within one runloop tick — no flash of unstyled content).
- Edits in Source mode are immediately visible if toggled back to Preview.

---

### Phase 4 — Clipboard and PDF Export

**Goal:** Copy Formatted (rich text clipboard for Outlook/Word) and PDF export both work.

**Tasks:**

4.1 `HTMLRenderer.swift`:
- Takes `Markdown.Document` AST → returns complete HTML string with inline CSS only.
- Typography per §7.1.
- Code blocks: `<pre><code style="...">`.
- Tables: alternating row backgrounds via per-row inline style (not CSS classes).

4.2 `RTFRenderer.swift`:
- Trivial wrapper: takes the current `NSAttributedString` (force a fresh AST-walk attribute pass for a clean "preview-style" copy without dimmed markers) → `data(from:documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])`.

4.3 `DocumentWindowController.copyFormatted(_:)`:
- Determine range (selection if non-empty, else full document).
- Generate HTML + RTF + plain text for that range.
- Write all three types to `NSPasteboard.general`.
- Bound to `Edit > Copy Formatted` (`Cmd+Shift+C`).

4.4 `PDFExporter.swift`:
- Build full HTML via `HTMLRenderer`, wrap in `<html><body style="max-width: 740px; margin: 40px auto; ...">`.
- Load into offscreen `WKWebView` (size 595pt wide).
- After `didFinish`, evaluate JS `document.body.scrollHeight` to size the PDF rect.
- Call `createPDF(configuration:)` with `rect = CGRect(x: 0, y: 0, width: 595, height: scrollHeight)`.
- Present `NSSavePanel` filtered to `.pdf`, default filename, default directory = document's directory.

4.5 Wire to `File > Export as PDF...` (`Cmd+Shift+E`) and toolbar button.

**Validation:**
- Copy Formatted → paste into Outlook for Mac: headings, bold, italic, code blocks, lists, tables all correct.
- Same paste into Microsoft Word: same result.
- PDF export: single tall page, A4-width, typography matches Live Preview, file size reasonable.
- Plain text paste (`Cmd+V` into Terminal) pastes the Markdown source, not HTML markup.

---

### Phase 5 — *(intentionally empty)*

The original Phase 5 (Finder Sync Extension) is dropped. Finder integration is provided via `CFBundleDocumentTypes` Open With registration, declared in Phase 1.

---

### Phase 6 — Empty State, Format Menu, Polish

**Goal:** Complete the non-editing UI states, the Format menu, and accessibility.

**Tasks:**

6.1 `EmptyStateView.swift` per §6.5; shown when no document is open.

6.2 YAML front matter card per §6.2.

6.3 Format menu per §6.7 — all actions edit the source string via `NSTextView.insertText` with proper undo grouping.

6.4 About window: `NSApplication.shared.orderFrontStandardAboutPanel`.

6.5 Preferences (minimal):
- Font size: Small (14pt) / Medium (16pt, default) / Large (18pt).
- Stored in `UserDefaults`.

6.6 Menu bar completeness:
- **File:** New, Open, Open Recent, Close, Save, Save As, Export as PDF, separator, Share (via `NSSharingServicePicker`).
- **Edit:** Undo, Redo, sep, Cut, Copy, Copy Formatted, Paste, Select All, sep, Find/Replace.
- **Format:** per §6.7.
- **View:** Toggle Preview / Source, Actual Size.
- **Window:** standard.
- **Help:** Quick Markdown Help (opens bundled `Help.md` read-only).

6.7 Accessibility: VoiceOver labels on toolbar items, empty state, banner. Tab order logical.

**Validation:**
- Empty state shown when no file open; drag opens a file.
- Preferences persist across launches.
- Menu items correctly enabled/disabled when no document is open.
- VoiceOver navigates main window without issues.

---

### Phase 7 — App Store Submission Preparation

**Goal:** Mac App Store-ready binary.

**Tasks:**

7.1 App icon set (`AppIcon.appiconset`) at 16/32/64/128/256/512/1024pt (1x and 2x). Clean document icon with stylised `#`, accent-colour gradient, macOS Tahoe-era rounded square.

7.2 Build settings:
- `CODE_SIGN_STYLE = Automatic`
- `ENABLE_HARDENED_RUNTIME = YES`
- `SWIFT_STRICT_CONCURRENCY = complete`
- `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1`

7.3 `PrivacyInfo.xcprivacy`:
- No data collected.
- Declared API reasons: `NSPrivacyAccessedAPICategoryUserDefaults` (CA92.1), `NSPrivacyAccessedAPICategoryFileTimestamp` (C617.1) — needed for `NSFilePresenter` change detection.

7.4 Localisation: English only for v1.

7.5 Notarise via Xcode Organiser before TestFlight.

7.6 App Store metadata:
- **Name:** Quick Markdown
- **Subtitle:** Beautiful Markdown Editor
- **Category:** Productivity
- **Description:** (see below)
- **Keywords:** markdown, editor, md, developer tools, writing, ai, llm

**Draft description:**
> Quick Markdown is a beautiful, focused Markdown editor for macOS. Open any .md file and see your content rendered instantly — clean typography, proper headings, styled code blocks, and formatted tables. No clutter, no project management, no learning curve.
>
> Watch your AI assistant write to a Markdown file in real time as Quick Markdown follows the tail. Edit with a hybrid live-preview editor that looks rendered but stores plain Markdown. Switch to Plain Source view when you need to see the raw text.
>
> Copy your formatted document directly into Outlook or Word with a single shortcut. Export to PDF in one click. Quick Markdown is the companion app for every .md file your AI assistant, coding tool, or colleague sends you.
>
> Requires macOS 26 Tahoe or later.

7.7 Screenshots (3): Live Preview with rich sample, Plain Source view, PDF export panel.

**Validation:**
- `codesign --verify --deep --strict` passes.
- `spctl --assess --type execute` reports "accepted".
- Sandbox entitlements verified via `codesign -d --entitlements :-`.
- TestFlight build passes internal testing.

---

## 14. Non-Functional Requirements

| Requirement | Target |
|---|---|
| Launch time (cold) | < 0.8s to interactive |
| File open time (10,000-word .md) | < 0.5s to rendered |
| Memory usage (typical document) | < 80MB |
| Re-render latency after keystroke | < 100ms |
| Cursor-move marker reveal latency | < 100ms |
| File-watcher debounce | 150ms |
| PDF export time (typical document) | < 3s |
| Crash-free rate | > 99.9% |

---

## 15. Dependencies Summary

| Dependency | Source | Phase |
|---|---|---|
| `swift-markdown` | SPM — `https://github.com/apple/swift-markdown` | Phase 2 |
| `WKWebView` | macOS SDK | Phase 4 |

---

## 16. Resolved Architectural Decisions (PRD revision 2.0)

| # | Decision |
|---|---|
| 1 | Deployment target: macOS 26.0 only |
| 2 | Hybrid live-preview editor: source-is-truth, display attributes layered, marker-reveal-near-cursor |
| 3 | No Finder Sync Extension; use `CFBundleDocumentTypes` Open With |
| 4 | Classic save model (no autosave; dirty dot; explicit `Cmd+S`) |
| 5 | PDF = single tall page via `WKWebView.createPDF` |
| 6 | `Cmd+Shift+S` = Save As; `Cmd+Shift+P` = Toggle Preview/Source |
| 7 | `UserDefaults` for preferences; no iCloud KVS |
| 8 | Live file watching via `NSFilePresenter` with 150ms debounce, follow-mode, reload banner on conflict |
| 9 | Format menu with `Cmd+B/I/E/K`, Insert Table, Insert Code Block, Toggle Task, Heading 1/2/3 |

---

*End of PRD — Quick Markdown v1.0, revision 2.0*
