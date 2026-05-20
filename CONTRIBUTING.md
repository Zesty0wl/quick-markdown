# Contributing to Quick Markdown

Thanks for taking the time to contribute — small, focused PRs are very welcome.

Quick Markdown has a deliberately narrow scope. Before opening a large PR, please skim this whole document and the **Out of scope** section. It will save us both time.

---

## The design test

Every change should answer **yes** to:

> Does this make Quick Markdown better at opening, reading, editing, or sharing **a single Markdown file**?

It is *not* a knowledge base, vault, project manager, plugin host, or sync engine. Features that pull the app in those directions will be politely declined.

Read [`QuickMarkdown_PRD.md`](QuickMarkdown_PRD.md) for the full product vision and the explicit out-of-scope list.

---

## Ways to help

### Good first PRs

- Bug fixes with a reproducer in the description
- Keyboard-shortcut polish (Format menu, mode switching)
- Markdown rendering edge cases (GFM tables, nested lists, footnotes, front matter)
- Accessibility improvements (VoiceOver labels, focus order, contrast)
- Documentation: clearer README, code comments where the *why* isn't obvious

### Bigger discussions first, please

Open an issue **before** starting work on:

- New top-level menus or toolbar items
- New file formats (anything beyond `.md` / `.markdown`)
- Anything that adds a new dependency
- Anything that touches the sandbox entitlements
- New preferences UI

---

## Getting set up

```bash
# Prereqs: Xcode 26+, optionally xcodegen
brew install xcodegen

git clone https://github.com/Zesty0wl/quick-markdown.git
cd quick-markdown

# Re-generate the project from project.yml whenever you edit it
xcodegen generate

# Build
xcodebuild -scheme QuickMarkdown -configuration Debug build

open QuickMarkdown.xcodeproj
```

`project.yml` is the source of truth for the Xcode project. The generated `QuickMarkdown.xcodeproj/project.pbxproj` is checked in so contributors without xcodegen can open it, but **any structural change (new files, dependencies, build settings) must go in `project.yml` and be re-generated**, otherwise the next `xcodegen generate` will silently revert your work.

---

## Code style

- **Swift 6, strict concurrency.** The project is built with `SWIFT_STRICT_CONCURRENCY=complete`. Don't add `@unchecked Sendable` to silence the compiler — fix the actual isolation issue.
- **AppKit, not SwiftUI.** The app is `NSDocument`-based. New views should be `NSView` / `NSViewController`. SwiftUI is acceptable for small, leaf-level views if it genuinely simplifies things.
- **No new dependencies without an issue.** `swift-markdown` is the only third-party dependency and we'd like to keep the count low.
- **Sandbox is non-negotiable.** Don't add entitlements unless an issue is open and a maintainer has signed off.
- **Two-space indent, 100-column soft limit** (matches the existing files).
- **Comments explain *why*, not *what*.** If the code is doing something surprising (workaround for an AppKit bug, sandbox limitation, AppKit timing quirk), say so — future-you will thank you.
- **Match the surrounding style.** Don't reformat files you're not changing.

---

## Commit and PR conventions

- One logical change per PR. If you have two unrelated fixes, send two PRs.
- Imperative-mood commit subject, ≤ 72 chars (e.g. `Fix crash when opening empty file`).
- Body: explain *why* the change is needed, not what the diff shows.
- Reference the issue: `Fixes #42` / `Refs #42`.
- Keep the diff tight — no drive-by reformatting, no auto-generated `.xcodeproj` churn unrelated to your change.

---

## Testing your change

Manually, at minimum, before opening a PR:

1. **Build clean:** `xcodebuild -scheme QuickMarkdown -configuration Debug clean build` succeeds with no new warnings.
2. **Open a `.md` file** from Finder via *Open With → Quick Markdown*.
3. **Edit, save, close** without crashes; dirty dot appears and clears correctly.
4. **Toggle Preview / Source** (⇧⌘P) — the cursor position is preserved.
5. **Copy Formatted** (⇧⌘C) and paste into Outlook/Mail/TextEdit — formatting survives.
6. **External edit:** open the file in another editor, save, watch Quick Markdown reload (or show the banner if you have dirty edits).

There's no automated test suite yet — adding one is a welcome PR.

---

## Reporting bugs

Open an [issue](https://github.com/Zesty0wl/quick-markdown/issues/new/choose) using the **Bug report** template. The single most useful thing you can do is paste a **minimal Markdown sample** that reproduces the problem.

---

## License

By submitting a pull request you confirm that:

- Your contribution is your own work (or you have permission to submit it).
- You agree to license it under the [MIT License](LICENSE).
