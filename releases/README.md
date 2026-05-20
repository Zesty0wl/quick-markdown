# Releases (local-only)

Drop signed and notarized distributables here before publishing.

Everything in this folder is gitignored except this `README.md` and `.gitkeep`,
so the binaries never enter git history — they live only on the corresponding
GitHub Release.

## Conventions

- Versioned filenames, for example `Quick Markdown-1.0.1.pkg`.
- Generate a checksum next to the artifact:

  ```bash
  shasum -a 256 'Quick Markdown-1.0.1.pkg' > 'Quick Markdown-1.0.1.pkg.sha256'
  ```

- Publish with the `Release` workflow (see [`../RELEASING.md`](../RELEASING.md))
  or with the GitHub CLI, for example:

  ```bash
  gh release create v1.0.1 \
    'releases/Quick Markdown-1.0.1.pkg' \
    'releases/Quick Markdown-1.0.1.pkg.sha256' \
    --title 'Quick Markdown 1.0.1' \
    --notes-file releases/notes-1.0.1.md
  ```
