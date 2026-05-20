# Releasing Quick Markdown

This repository uses a manual GitHub Actions release workflow to publish the
signed and notarized installer package.

## Prerequisites

- A signed and notarized installer package placed in the local `releases/`
  folder (example: `releases/Quick Markdown-1.0.1.pkg`). The `releases/`
  folder is gitignored so binaries never enter git history.
- Updated `CHANGELOG.md` entry for the release

## Create a release (GitHub CLI, recommended)

Run locally from the repo root:

```bash
shasum -a 256 'releases/Quick Markdown-1.0.1.pkg' \
  > 'releases/Quick Markdown-1.0.1.pkg.sha256'

gh release create v1.0.1 \
  'releases/Quick Markdown-1.0.1.pkg' \
  'releases/Quick Markdown-1.0.1.pkg.sha256' \
  --title 'Quick Markdown 1.0.1' \
  --notes-file releases/notes-1.0.1.md
```

## Create a release (GitHub Actions)

1. Open Actions in GitHub and run the `Release` workflow.
2. Fill in:
   - `tag`: release tag (for example `v1.0.1`)
   - `release_name`: human-readable title
   - `artifact_path`: path to the notarized package (for example
     `releases/Quick Markdown-1.0.1.pkg`)
   - `draft`: `true` if you want to review before publishing
   - `prerelease`: set as needed
3. Run workflow.

The workflow will:

- Verify the artifact exists
- Generate a SHA256 checksum file beside it
- Create the GitHub release
- Upload both the package and checksum as release assets

## Verify the release asset locally

```bash
spctl -a -vv -t install 'releases/Quick Markdown-1.0.1.pkg'
pkgutil --check-signature 'releases/Quick Markdown-1.0.1.pkg'
shasum -a 256 'releases/Quick Markdown-1.0.1.pkg'
```
