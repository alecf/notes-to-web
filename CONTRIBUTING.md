# Contributing

## Setup

You need macOS 14+ and a Swift toolchain. `xcode-select --install` is sufficient;
a full Xcode install is not required and no Xcode project exists.

```sh
make        # list targets
swift test  # run tests
make run    # build and launch the app
```

## Testing against your own notes

The parser and renderer are pure functions over a decoded note, so most work can
be done with fixtures in `Tests/NotesToWebKitTests/Fixtures/`. To capture a new
fixture from your own library:

```sh
make fixture NOTE="part of the note title"
```

This writes the decompressed protobuf for the matching note. **Read it before
committing** — it contains that note's full text.

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
