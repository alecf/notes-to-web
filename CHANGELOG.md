# Changelog

## 0.2.0

**Requires macOS 26 or later on Apple Silicon.** Support for macOS 14–15 and
Intel Macs is dropped; release binaries are no longer universal.

- **Compress videos for the web.** A phone's 50 Mbps clip is re-encoded to a
  bounded bitrate, typically shrinking an export by an order of magnitude. The
  bitrate is derived from a per-file size budget rather than picked, so files
  reliably land under the 25 MB limit that Cloudflare and most free static hosts
  enforce. H.264 by default; HEVC available for roughly 40% smaller files where
  browser support allows.
- The export sheet now costs the job before you commit, showing real
  before/after sizes and naming any video that will still be too large.
- Progress is weighted by bytes rather than file count, so the bar reflects the
  work actually remaining, and names the file being compressed.
- **Publish to Cloudflare.** Notes exported into a site folder are served as
  subpaths of one domain — `/workout-plan/`, `/recipes/` — with a generated
  index page listing them. Unchanged files are skipped on re-publish.
- Credentials are stored in the macOS Keychain. Nothing is embedded in the app.
- Exports keep a stable URL: re-exporting a note overwrites its existing path
  instead of creating a new one beside it.

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
