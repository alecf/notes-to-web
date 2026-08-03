# notes-to-web — Design

**Date:** 2026-08-03
**Status:** Accepted

## Goal

A native macOS app that turns a single Apple Notes note into a directory of static
files (`index.html` + `assets/`) that can be published verbatim to a static host
such as Cloudflare Pages. Embedded videos must play inline in the published page.

## The finding that drives the architecture

The obvious approach — Notes' AppleScript `body` property, which claims to return
"the HTML content of the note" — is unusable for this goal. Measured against a real
17-video workout note:

| | AppleScript `body` | `NoteStore.sqlite` protobuf |
|---|---|---|
| Video attachments | **Silently dropped.** No tag, no marker, no `cid:` | Present, with exact inline position |
| Image attachments | Inlined as multi-MB base64 `data:` URIs | Referenced by UUID; file on disk |
| Headings / lists / checklists | Flattened to `<div>` | Preserved as structured style runs |

The `attachment` class *does* expose a `content identifier` described as "the
content-id URL in the note's HTML" — but for video attachments no such reference is
ever emitted into the body. The position information simply does not exist in the
AppleScript representation.

So the app reads Notes' own store instead.

### What the store gives us

`ZICNOTEDATA.ZDATA` is a gzipped protobuf. Decoded:

```
NoteStoreProto.document.note
  ├─ note_text : String            # attachments appear as U+FFFC (OBJECT REPLACEMENT CHARACTER)
  └─ attribute_run[] : AttributeRun
       ├─ length          (1)      # in UTF-16 code units
       ├─ paragraph_style (2)      # style_type: title/heading/lists/checklist
       ├─ font            (3)
       ├─ font_weight     (5)      # bold / italic
       ├─ underlined      (6)
       ├─ strikethrough   (7)
       ├─ link            (9)
       └─ attachment_info (12)     # { identifier, type_uti }
```

Run lengths sum exactly to the text length, so walking the runs in order
reconstructs the document with attachments in their true positions.

Attachment files resolve as:

```
ZICCLOUDSYNCINGOBJECT[ZIDENTIFIER = <attachment uuid>]
  → ZMEDIA    → media row  → ZIDENTIFIER, ZFILENAME
  → ZACCOUNT1 → account row → ZIDENTIFIER

~/Library/Group Containers/group.com.apple.notes/Accounts/<account>/Media/<media>/<generation>/<filename>
```

The `<generation>` directory (e.g. `1_<uuid>`) is not recorded in the columns we
read, so the resolver globs one level deeper and falls back to "the single regular
file under `Media/<media>/`".

### Consequence: Full Disk Access

`~/Library/Group Containers/` is TCC-protected. The app must be granted **Full Disk
Access** once. This is not optional — it is the only path to correct video
placement, and every serious Notes exporter requires it. The app detects the missing
grant and presents a first-run screen that deep-links to the right System Settings
pane rather than failing with a permission error.

The store is opened by snapshot-copying `NoteStore.sqlite` plus its `-wal` and
`-shm` sidecars to a temp directory, then reading that copy. This avoids contending
with a running Notes.app and correctly picks up un-checkpointed WAL contents (the
WAL is routinely hundreds of MB).

**AppleScript is still used**, for one thing it is genuinely better at: enumerating
accounts and folders for the browser UI, and as a fallback path for reading
attachment bytes when a media file is not present on disk. That keeps the browsing
experience working before Full Disk Access is granted.

## Output

One note → one directory. Nothing inlined; videos are far too large for that.

```
my-workout/
  index.html
  assets/
    style.css
    IMG_5167.mov
    IMG_5167.poster.jpg
    ...
```

Videos render as:

```html
<video controls preload="metadata" playsinline poster="assets/IMG_5167.poster.jpg">
  <source src="assets/IMG_5167.mov" type="video/quicktime">
</video>
```

Poster frames are generated with AVFoundation's `AVAssetImageGenerator` so the page
shows a still frame rather than a black rectangle before playback. Playback is
inline — no scrolling away, no new tab.

`.mov` (H.264/HEVC in a QuickTime container) plays in Safari and in Chrome on
macOS. For broad browser support the exporter offers an optional remux to `.mp4`
via AVFoundation's `AVAssetExportSession` (no ffmpeg dependency), on by default.

## UI

`NavigationSplitView`, three columns, standard macOS idiom:

1. **Sidebar** — accounts, each with its folder tree. Note counts as badges.
2. **List** — notes in the selected folder: title, snippet, modified date, and a
   badge showing attachment count. Searchable.
3. **Detail** — a `WKWebView` rendering *exactly the HTML the exporter produces*, so
   the preview is the artifact. A toolbar `Export…` button opens a directory picker,
   shows determinate progress (assets dominate the time), then offers
   *Reveal in Finder*.

First run without Full Disk Access shows an explanatory gate with a button that
opens `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.

## Build

SwiftPM only; no Xcode project, no `.xcodeproj` to keep in sync.

- `swift build` produces the executable.
- `make app` assembles `NotesToWeb.app` (Info.plist, icon, ad-hoc codesign).
- `make run` builds and launches.

Logic lives in a `NotesToWebKit` library target with no UI dependencies, so the
parser and renderer are unit-testable via `swift test` against fixture data.

### Dependencies

| Library | Why |
|---|---|
| [swift-protobuf](https://github.com/apple/swift-protobuf) | Apple's protobuf runtime; decodes the note document |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | Ergonomic, safe SQLite access |

Generated protobuf code is committed, so building the app needs only a Swift
toolchain. `make proto` regenerates it and builds `protoc-gen-swift` from source, so
even that path needs no Homebrew packages beyond `protoc`.

Gzip is handled by `NSData.decompressed(using: .zlib)` after parsing off the gzip
header — no zlib dependency.

## Non-goals (v1)

- Exporting multiple notes at once. One note, one page.
- Editing notes. Read-only, always.
- Password-protected notes. Detected and skipped with a clear message.
- Notes tables and scanned-document attachments. Rendered as a download link rather
  than reconstructed.
