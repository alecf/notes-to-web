# Changelog

## 0.1.1

- Add an app icon, so the app is identifiable in the Dock and Finder. The icon
  is generated from `docs/logo.svg`; the 0.1.0 binary shipped without one.

## 0.1.0

First release.

- Browse Notes accounts, folders, and notes; search within a folder.
- Preview a note exactly as it will be published, with videos playable inline.
- Export one note to `index.html` plus an `assets/` directory, publishable
  verbatim to any static host.
- Videos are placed where they actually sit in the note — read from Notes' own
  store, because the AppleScript interface drops them entirely. They are
  remuxed to MP4 and given generated poster frames.
- Headings, lists, checklists, inline formatting, and links are preserved.
