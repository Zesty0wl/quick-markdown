# Link smoke test

This file exercises the two fixes in 1.0.6:

1. In-document anchor links resolving to heading slugs.
2. Relative `file://` links — both existing and missing.

## Anchor links

- Jump to [Part 6.5 — Sync an out-of-date fork](#part-65--sync-an-out-of-date-fork)
- Jump to [Final section](#final-section)
- Jump to a [missing anchor](#does-not-exist) (should no-op silently — that's expected for a real missing target)

## Relative links

- Sibling file that exists: [README in test-files](./README.md)
- File two levels up that **doesn't** exist: [bogus glossary](../../GLOSSARY.md)
  Expected: beep + Finder reveal of nearest existing ancestor folder.
- Welcome doc sibling: [01-welcome.md](./01-welcome.md)

## External links (sanity)

- [GitHub](https://github.com)

---

Filler content so the page is tall enough to actually scroll when an
anchor click jumps.

Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod
tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim
veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea
commodo consequat.

Duis aute irure dolor in reprehenderit in voluptate velit esse cillum
dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non
proident, sunt in culpa qui officia deserunt mollit anim id est laborum.

Sed ut perspiciatis unde omnis iste natus error sit voluptatem
accusantium doloremque laudantium, totam rem aperiam, eaque ipsa quae ab
illo inventore veritatis et quasi architecto beatae vitae dicta sunt
explicabo.

Nemo enim ipsam voluptatem quia voluptas sit aspernatur aut odit aut
fugit, sed quia consequuntur magni dolores eos qui ratione voluptatem
sequi nesciunt.

Neque porro quisquam est, qui dolorem ipsum quia dolor sit amet,
consectetur, adipisci velit, sed quia non numquam eius modi tempora
incidunt ut labore et dolore magnam aliquam quaerat voluptatem.

## Part 6.5 — Sync an out-of-date fork

If the anchor link at the top jumped you here, the heading-slug fix is
working. The expected slug is `part-65--sync-an-out-of-date-fork` —
two hyphens between `65` and `sync` because the `.` in `6.5` and the
em-dash both got stripped, leaving two spaces that turn into hyphens.

## Final section

End of the file.
