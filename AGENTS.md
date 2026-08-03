# AGENTS.md

Guidance for AI coding agents working in this repository. `CLAUDE.md` is a
symlink to this file.

## What this is

A macOS app that exports a single Apple Notes note to a static website directory
(`index.html` + `assets/`), preserving embedded videos as inline `<video>`
elements.

## Build and test

```sh
swift build        # build the library and executable
swift test         # unit tests (NotesToWebKit only — no UI, no Notes access)
make app           # assemble NotesToWeb.app
make run           # build and launch
```

There is **no Xcode project** and none should be added. Everything builds from
the command line via SwiftPM. Do not create `.xcodeproj` or `.xcworkspace` files.

## Architecture

- `Sources/NotesToWebKit` — all logic. No AppKit/SwiftUI imports. Testable.
  - `Store/` — snapshot and read `NoteStore.sqlite` (GRDB)
  - `Model/` — decoded note document types
  - `Render/` — document → HTML
  - `Export/` — asset copying, poster frames, writing the output directory
- `Sources/NotesToWeb` — SwiftUI app. Should stay thin; push logic down into the kit.
- `Protos/` — protobuf schema; generated output is committed under
  `Sources/NotesToWebKit/Generated/`.

## Things that will bite you

**AppleScript's `note.body` is not a viable source of note content.** It silently
drops video attachments entirely and inlines images as base64. This was measured,
not assumed. Read the store instead. See
`docs/plans/2026-08-03-notes-to-web-design.md`.

**Attribute run lengths are UTF-16 code units**, not Characters and not bytes.
Index into `String.UTF16View` or you will corrupt any note containing emoji or
non-BMP characters.

**Attachments appear in `note_text` as U+FFFC** (OBJECT REPLACEMENT CHARACTER).
That character is the anchor; the attachment's identity comes from the
corresponding attribute run's `attachment_info`.

**Media file paths have an undocumented generation directory.** The layout is
`Media/<media-uuid>/<generation>/<filename>`, and `<generation>` is not in the
columns we query. Resolve by globbing, and keep the existing fallbacks.

**The `-wal` file is routinely hundreds of megabytes** and Notes.app holds the
database open. Always snapshot `NoteStore.sqlite` *and* its `-wal` and `-shm`
sidecars together before opening, or you will read stale data.

**Full Disk Access is required** and is keyed to the signed binary. After a
rebuild, macOS may treat the app as new — if the app suddenly reports no
permission during development, toggle it off and on in System Settings.

## Hard rules

- **Never write to the user's Notes data.** Copy, then open read-only. Any change
  that opens the live store for writing is a bug, not a tradeoff.
- **Never inline media as `data:` URIs.** The whole point is publishable output;
  a base64 video is neither.
- Do not commit fixtures captured from a real Notes library without reading them
  first — they contain full note text.

## Conventions

- Swift 6 language mode, strict concurrency. Long-running work (asset copying,
  poster generation) is `async` and reports progress.
- Errors surface to the user as actionable text, not raw `Error` descriptions.
  A missing media file should say which attachment and why, not `Error Domain=…`.
- New dependencies need a justification recorded in the design doc.
