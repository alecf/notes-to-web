# Contributing

## Setup

You need macOS 14+ and a Swift toolchain. `xcode-select --install` is sufficient;
a full Xcode install is not required and no Xcode project exists.

```sh
make        # list targets
swift test  # run tests
make run    # build and launch the app
```

## Testing

`swift test` runs the parser, renderer, and gzip tests. They build note documents
programmatically rather than shipping real notes as fixtures, so they need no
permissions and contain nobody's personal data.

There is also a smoke suite that runs against your actual Notes library. It is
skipped unless you ask for it:

```sh
make live   # NOTES_TO_WEB_LIVE=1 swift test
```

It decodes every note you have and checks that attachments resolve. Run it after
touching anything under `Store/` or `Model/`. Do not commit fixtures captured
from a real library — they contain full note text.

## Regenerating protobuf code

`Sources/NotesToWebKit/Generated/NoteStore.pb.swift` is committed so that a plain
`swift build` works. If you change `Protos/NoteStore.proto`:

```sh
make proto
```

This builds `protoc-gen-swift` from the SwiftProtobuf package, so you only need
`protoc` itself on your PATH.

## Notes on the note format

`docs/plans/2026-08-03-notes-to-web-design.md` documents the store layout and the
protobuf schema, including how it was verified. If you discover a field or style
type we handle incorrectly, please update that document alongside the fix.

## Style

- Logic goes in `NotesToWebKit`; `NotesToWeb` is UI only and should stay thin.
- No new dependencies without a reason recorded in the design doc.
- Never write to the user's Notes data. The store is copied and opened read-only.
