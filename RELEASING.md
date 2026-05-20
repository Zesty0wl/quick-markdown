# Releasing Quick Markdown

This repository uses a manual GitHub Actions release workflow to publish the
signed and notarized installer package.

## Prerequisites

- A signed and notarized installer package committed to the branch you will
  release from (example: `./Quick Markdown-1.0.1.pkg`)
- Updated `CHANGELOG.md` entry for the release

## Create a release

1. Push the branch containing the release artifact.
2. Open Actions in GitHub and run the `Release` workflow.
3. Fill in:
   - `tag`: release tag (for example `v1.0.1`)
   - `release_name`: human-readable title
   - `artifact_path`: path to the notarized package
   - `draft`: `true` if you want to review before publishing
   - `prerelease`: set as needed
4. Run workflow.

The workflow will:

- Verify the artifact exists
- Generate a SHA256 checksum file beside it
- Create the GitHub release
- Upload both the package and checksum as release assets

## Verify the release asset locally

```bash
spctl -a -vv -t install "Quick Markdown-1.0.1.pkg"
pkgutil --check-signature "Quick Markdown-1.0.1.pkg"
shasum -a 256 "Quick Markdown-1.0.1.pkg"
```
