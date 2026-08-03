# notes-to-web

Turn an Apple Notes note into a publishable webpage — videos and all.

Pick a note, click **Export**, get a directory of static files you can upload
verbatim to Cloudflare Pages, Netlify, S3, or any static host.

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

Requires macOS 14+ and a Swift toolchain (`xcode-select --install` is enough).

```sh
git clone https://github.com/alecf/notes-to-web
cd notes-to-web
make app
open NotesToWeb.app
```

`make install` copies it to `/Applications`.

## Usage

1. Launch the app and grant Full Disk Access when prompted.
2. Browse your accounts and folders in the sidebar; pick a note.
3. The preview pane shows exactly what will be exported.
4. **Export…** → choose a directory → done.
5. Upload that directory. For Cloudflare Pages:

   ```sh
   npx wrangler pages deploy my-workout
   ```

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
make          # list targets
swift test    # unit tests for the parser and renderer
make app      # assemble the .app bundle
make run      # build and launch
```

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
