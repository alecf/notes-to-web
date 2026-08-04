<img src="docs/logo.svg" alt="" width="96" align="left" hspace="4" vspace="4">

# notes-to-web

Turn an Apple Notes note into a publishable webpage — videos and all.

<br clear="left">

Pick a note, click **Export**, get a directory of static files you can upload
verbatim to Cloudflare, Netlify, S3, or any static host — or let the app publish
it for you.

```
my-workout/
├── index.html
└── assets/
    ├── style.css
    ├── IMG_5167.mp4
    ├── IMG_5167.poster.jpg
    └── …
```

Videos embedded in the note stay embedded in the page — they play inline, in
place, with a poster frame. No scrolling away, no new tabs, nothing inlined as
base64.

They are also compressed on the way out. Straight off an iPhone, one workout
note came to 538 MB across 17 clips, with single files up to 54 MB — over
Cloudflare's 25 MB per-file limit, and over half of GitHub Pages' 1 GB site
limit. Re-encoding at a bounded bitrate is what makes that note publishable at
all.

## Why this exists

Someone shares a set of workouts with you as an Apple Note, with a demo video
after each exercise. You want that on the web. Notes will export a PDF (videos
become dead rectangles) or you can copy-paste (videos vanish). Neither works.

## Why it needs Full Disk Access

Notes' AppleScript API exposes a `body` property documented as "the HTML content
of the note". For a note with 17 videos, that HTML contains **zero references to
any of them** — no tag, no placeholder, no position. Images fare little better:
they come back as multi-megabyte base64 `data:` URIs.

The position information only exists in Notes' own store, at
`~/Library/Group Containers/group.com.apple.notes/`, which macOS protects. So
notes-to-web reads that store directly, in read-only mode, from a temporary
snapshot copy. It never writes to your Notes data.

You grant Full Disk Access once, on first run. The app will walk you through it.

## Install

Requires macOS 26 or later on Apple Silicon.

**Download** the latest `NotesToWeb-*.zip` from
[Releases](https://github.com/alecf/notes-to-web/releases), unzip, and move the
app to Applications. It is ad-hoc signed rather than notarized, so macOS will
refuse to open it until you clear the quarantine flag:

```sh
xattr -d com.apple.quarantine /Applications/NotesToWeb.app
```

**Or build it**, which skips that step. A Swift toolchain is all you need —
`xcode-select --install` is enough, and there is no Xcode project.

```sh
git clone https://github.com/alecf/notes-to-web
cd notes-to-web
make app        # or: make install, to put it in /Applications
open NotesToWeb.app
```

Release binaries are arm64 and built by
[GitHub Actions](.github/workflows/release.yml) on a clean runner, from a tag,
with no developer machine involved. Each release lists the SHA-256 of its zip.

## Usage

1. Launch the app and grant Full Disk Access when prompted.
2. Browse your accounts and folders in the sidebar; pick a note.
3. The preview pane shows exactly what will be exported.
4. **Export…** → check the size estimate → done.
5. Upload the directory anywhere, or let the app publish it.

## Publishing

Set a **site folder** in Settings and every note you export lands in its own
subfolder, so they publish together as one site:

```
alecs-notes/
├── index.html          ← generated, lists every note
├── workout-plan/
└── knife-skills/
```

served as `/workout-plan/`, `/knife-skills/`, and so on. Re-exporting a note
keeps its existing path, so links you've already shared don't break.

Connect a Cloudflare account in Settings and the app uploads it for you.
Unchanged files are skipped, so republishing one note out of twenty uploads only
that note.

You create the API token yourself and it is stored in the macOS Keychain —
nothing is embedded in this app, and you can revoke it at any time. Or ignore
publishing entirely and upload the folder however you like; the output is plain
static files.

Adding another host means writing one `SitePublisher` and registering it — see
[the publishing design](docs/plans/2026-08-03-publishing-design.md).

## Video

Videos are re-encoded for the web by default, at a bitrate derived from a
per-file size budget rather than a fixed quality preset. That is what keeps
files under the 25 MB limit most free static hosts enforce.

H.264 in MP4 is the default: hardware encoded, plays everywhere, with the moov
atom moved to the front so playback starts before the download finishes. HEVC is
available for roughly 40% smaller files where browser support allows. AV1 and
WebM are not offered — VideoToolbox has no encoder for either, and bundling a
software encoder would cost a large dependency and one to two orders of
magnitude in speed.

Turn compression off in Settings to keep the originals byte for byte.

## What gets preserved

| Note content | Exported as |
|---|---|
| Videos | `<video controls playsinline>` with a generated poster frame |
| Images | `<img>` in `assets/`, never inlined |
| Title / headings / subheadings | `<h1>` / `<h2>` / `<h3>` |
| Bulleted, dashed, numbered lists | `<ul>` / `<ol>` |
| Checklists | Checkbox list, checked state preserved |
| Bold, italic, underline, strikethrough, monospace | Corresponding tags |
| Links | `<a>` |
| Other attachments (PDFs, scans) | Download link |

Password-protected notes are skipped — the app tells you rather than exporting
something empty.

## Development

```sh
make            # list targets
swift test      # unit tests for the parser and renderer
make app        # assemble the .app bundle
make run        # build and launch
make dist       # universal, zipped bundle (what releases ship)
```

The app icon is generated from `docs/logo.svg` by `scripts/make-icon.sh`. The
resulting `.icns` is committed, so you only need to run it if you change the
logo (and you'll need `brew install librsvg`).

Logic lives in `Sources/NotesToWebKit` with no UI dependencies, so the note
parser and HTML renderer are testable without launching anything.

There is no Xcode project — everything builds from the command line via SwiftPM.
See [`docs/plans/2026-08-03-notes-to-web-design.md`](docs/plans/2026-08-03-notes-to-web-design.md)
for the architecture and the reverse-engineered note format.

## Prior art

The Notes protobuf format was independently verified for this project, but
[apple_cloud_notes_parser](https://github.com/threeplanetssoftware/apple_cloud_notes_parser)
is the reference documentation of the format and is worth your time if you want
to go deeper.

## License

MIT — see [LICENSE](LICENSE).
