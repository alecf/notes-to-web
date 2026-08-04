# AGENTS.md

Guidance for AI coding agents working in this repository. `CLAUDE.md` is a
symlink to this file.

## What this is

A macOS app that exports a single Apple Notes note to a static website directory
(`index.html` + `assets/`), preserving embedded videos as inline `<video>`
elements.

## Platform

**macOS 26 or later, Apple Silicon only.** No backwards compatibility, no
x86_64, no universal binaries. Write against the newest API spelling and do not
add `#available` guards. Reach for Apple Silicon paths where they matter —
notably GPU-backed `CIContext` and the hardware video encoders in the transcoder.

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
  - `Render/` — document → HTML, the site index page, and the exported
    stylesheet (`Stylesheet.swift`)
  - `Export/` — asset copying, video transcoding, poster frames, writing the
    output directory
  - `Publish/` — the site root (`SiteLibrary`), the provider-agnostic
    `SitePublisher` protocol, Keychain credential storage, and per-provider
    clients under `Publish/<Provider>/`
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

**Be careful adding SwiftPM resources to `NotesToWebKit`.** Releases used to be
universal, and `swift build --arch …` routes through a different build system
that does not generate `PackageResources`, so `.embedInCode` broke `make dist`
while `swift build` stayed green. Releases are now arm64-only and no longer pass
`--arch`, so that specific trap is gone — but a `.process` resource still needs
its bundle copied into the .app by hand, which `make app` does not do. Assets
belong in Swift literals; see `Render/Stylesheet.swift`. Verify any packaging
change with `make dist`, not just `swift build`.

**`AVAssetWriter` stalls if you finish one track before starting the other.**
Appending every video sample and only then the audio hangs indefinitely on
anything longer than a second or two. Interleave: on each pass, append to
whichever input reports `isReadyForMoreMediaData`. This cost a hung test run to
find, and it will look like a deadlock, not a bug.

**`writer.canApply(outputSettings:)` does not validate
`AVVideoEncoderSpecificationKey`.** That dictionary really is forwarded to
`VTCompressionSessionCreate` (verified empirically — a bogus `EncoderID` makes
the writer fail with "Cannot Encode"), but a bad spec surfaces at
`startWriting()`, not at `canApply`. VideoToolbox lists both hardware *and*
software H.264/HEVC encoders, so requiring hardware is meaningful — but only ask
for it after confirming `VTCopyVideoEncoderList` offers one for that codec, or
you get a hard failure instead of a graceful fall back.

**Scale video with `VTPixelTransferSession`, not `CIContext`.** The decoder
emits biplanar `420v`; Core Image has to convert to RGB and back even on the
GPU, while `VTPixelTransferSession` works on those buffers natively.

**MP4 container overhead is per *frame*, not a percentage.** Sample tables cost
a fixed ~21 bytes per frame regardless of how few bytes that frame's picture
took, so at 240 fps and a budget-constrained bitrate the container is 2.6% of
the file — eight times what the same clip costs at 30 fps. A flat percentage
margin cannot model this and will silently blow the size budget on
high-frame-rate footage. Measure frames, not ratios.

**Average bitrate is a target, not a ceiling** — VideoToolbox overshoots
`AVVideoAverageBitRateKey` by a couple of percent on real content, more on
synthetic noise. `kVTCompressionPropertyKey_DataRateLimits` *is* reachable
(unrecognised entries in `AVVideoCompressionPropertiesKey` are forwarded
verbatim to `VTCompressionSessionSetProperty`) and does enforce, but it lands
~30% under whatever cap it is given regardless of window length, so it wastes a
third of the budget if used as the primary mechanism. It is used only on the
rare corrective second pass, where certainty beats sharpness.

**CI runners advertise a hardware video encoder but block forever when one is
used.** `VTCopyVideoEncoderList` lists it, so detection alone does not save you,
and the job hangs with no output rather than failing — no timeout inside the
test can rescue a blocked VideoToolbox call. The encoding suites are gated on
`VideoTranscoder.canRunEncodingTests`, which additionally requires `CI` to be
unset. **Encoding changes are verified on real hardware only; CI will not catch
them.** Run `swift test` locally before shipping any transcoder change, and
`NOTES_TO_WEB_SCALE=1 NOTES_TO_WEB_SAMPLE=/path/to.mov swift test --filter Scale`
against real footage — synthetic fixtures did not catch the size-budget bug.

**Compressed video is cached; the staged sites are not a cache.**
`~/Library/Caches/…/transcodes` holds encodes keyed by source identity *and*
encode settings, so re-exporting an unchanged note is instant and changing any
setting correctly re-encodes. It is safe to delete. The staged site copies under
Application Support are **data**: a Workers deploy replaces a site's entire asset
set, so those copies are what stop publishing one note from deleting its
siblings. Do not "tidy" them into Caches.

**`URL.resourceValues` caches per URL instance.** Re-reading a file's size
through the same `URL` after rewriting it returns the *old* size, which makes
verify-then-correct loops silently no-op. It bit the transcoder's corrective
pass and then bit the cache key, where a rewritten file kept its old key and
would have served a stale encode. Use `FileManager.attributesOfItem`.

**`NWListener` with `allowLocalEndpointReuse` lets two listeners hold one port.**
It reads like the flag that stops "address already in use" after a crash, but it
also means a second listener binds a port the first still owns — so a stale OAuth
sign-in can silently swallow the callback meant for a newer one. It is off in
`OAuthCallbackListener`, and a test asserts the clash is an error. Related: a
bind failure arrives asynchronously as `.waiting`, not `.failed`, and not out of
the initializer — the listener politely retries forever, which to a sign-in is
indistinguishable from being broken. `start()` awaits `.ready` for this reason.

**The OAuth flow is unverified against the live service.** No client is
registered yet, so `bakedInClientID` is empty, the sign-in button is hidden, and
everything falls back to the API-token path. The scope names in
`CloudflareOAuthConfiguration` are a best guess from Cloudflare's single
documented example; the real list comes from `GET /oauth/scopes` with a token.
Do not treat the passing tests as evidence the handshake works end to end — they
prove the protocol mechanics, not Cloudflare's acceptance of them.

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
- **Never embed a secret in the app.** It is open source and shipped as a
  binary; a compiled-in token is a published token. Users create their own
  credential and it goes in the Keychain — never `UserDefaults`, never a log
  line, never an error message, never back onto the screen once stored.
  **An OAuth client ID is not a secret** and is committed on purpose — see
  `CloudflareOAuthConfiguration`. A client *secret* would break this rule, which
  is why the OAuth client is a public one using PKCE and there is no
  `clientSecret` field anywhere. Do not "fix" this by moving the client ID into
  a GitHub Actions secret; it is a public identifier like the bundle ID.
- **No new dependencies for video.** VideoToolbox has H.264 and HEVC encoders
  and nothing else; that constraint is the reason the exporter offers no AV1 or
  WebM, and it is a deliberate tradeoff, not an oversight. See
  `docs/plans/2026-08-03-publishing-design.md`.

## Conventions

- Swift 6 language mode, strict concurrency. Long-running work (asset copying,
  poster generation) is `async` and reports progress.
- Errors surface to the user as actionable text, not raw `Error` descriptions.
  A missing media file should say which attachment and why, not `Error Domain=…`.
- New dependencies need a justification recorded in the design doc.
