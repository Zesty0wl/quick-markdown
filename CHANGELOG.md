# Changelog

All notable changes to this project will be documented in this file.

The format is based on Keep a Changelog:
https://keepachangelog.com/en/1.1.0/

This project follows Semantic Versioning:
https://semver.org/spec/v2.0.0.html

## Unreleased

### Added

- In-app update notifier: on launch (once per 24 hours) and via the new
  "Check for Updates\u2026" menu item, the app polls the GitHub Releases
  API and offers a download link when a newer version is available.
  Sandbox-safe; uses only the existing `network.client` entitlement.

### Changed

- Bumped `MARKETING_VERSION` to 1.0.1 to match the shipped release.

## 1.0.1 - 2026-05-20

### Added

- Signed and notarized macOS installer package (`.pkg`) for GitHub releases.
- Open-source repository scaffolding for community health, contribution
    workflows, and CI.

## 1.0.0 - 2026-05-20

### Added

- Initial public release of Quick Markdown.
