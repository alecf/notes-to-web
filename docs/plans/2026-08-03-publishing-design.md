# Compressing and publishing

Design for the second half of notes-to-web: turning a 538 MB export into
something a free static host will actually accept, and getting it there.

Companion to [the original design](2026-08-03-notes-to-web-design.md), which
covers reading Notes and rendering HTML.

## The problem, in numbers

One real export of a workout note: **538 MB across 17 videos**, individually
**10–54 MB**. The exporter remuxed with `AVAssetExportPresetPassthrough`, so
output size equalled input size.

Measured against what hosts allow:

| Host | Per file | Whole site | Verdict on the raw export |
|---|---|---|---|
| Cloudflare Pages / Workers assets | **25 MiB** | not capped | Rejects the larger clips outright |
| GitHub Pages | 100 MiB | **1 GB** | Fits note #1, refuses note #2 |
| Vercel Hobby | — | **100 MB** per deployment | Cannot fit one note |
| Netlify free (2026) | — | ~15 GB/mo bandwidth | One viewer burns a slice of the month |

Every destination fails on the raw output, in a different place. So compression
is not a nice-to-have that comes after publishing — it is the thing that makes
publishing possible at all, and it is what makes *all four* destinations viable
rather than just one.

## Video encoding

### Why H.264/HEVC in MP4, and not AV1 or WebM

Checked, not assumed. `VTCopyVideoEncoderList` on macOS 26 / Apple Silicon
reports exactly two web-relevant encoders:

```
avc1  Apple H.264 (HW)   hardware
hvc1  Apple HEVC (HW)    hardware
```

There is **no AV1 encoder and no VP9 encoder** in VideoToolbox. AV1 would mean
bundling libaom or SVT-AV1: a large new dependency, CPU-only, and one to two
orders of magnitude slower than the hardware path — for a batch of 17 clips that
is the difference between under a minute and most of an hour. AGENTS.md requires
a recorded justification for new dependencies; this one does not earn it.

So:

- **H.264 High in MP4, `shouldOptimizeForNetworkUse = true`** (moov atom first,
  so playback starts before the file finishes downloading). This is the default.
  It plays in every browser on every platform.
- **HEVC as an opt-in.** Roughly 40% smaller at equal quality, hardware encoded,
  but decoding is uneven across browsers. When selected, the `<source>` carries
  `type="video/mp4; codecs=&quot;hvc1&quot;"` so a browser that cannot decode it
  falls through to the download link instead of showing a dead player.

Revisit if VideoToolbox ever ships an AV1 encoder.

### Bitrate is derived from a size budget, not picked

`AVAssetExportSession` presets cannot set a bitrate, so the transcoder is built
on `AVAssetReader` + `AVAssetWriter`, which can.

Quality tiers set a *ceiling*; the byte budget sets the real target:

```
videoBitrate = min(qualityCeiling, (budgetBytes * 8 / duration) - audioBitrate)
videoBitrate = max(videoBitrate, floor)     // never produce mush
```

Default budget is **22 MiB**, chosen to sit under Cloudflare's 25 MiB limit with
room for container overhead. A long clip can still overshoot even at the floor;
that sets `exceedsBudget` on the plan, which surfaces as a named warning in the
UI *before* the user commits, rather than a failed upload afterwards.

**A hard-won caveat: average bitrate is a target, not a ceiling.** Measured
against a real 4K clip (162.3 MB), the default settings produced 23.3 MB — an
86% reduction — but the largest single file landed at 23.0 MiB against a 22 MiB
budget, a 4.6% overshoot. VideoToolbox exceeds `AVVideoAverageBitRateKey` on
sustained high-motion content. Synthetic fixtures did not surface this; only
real footage did. A budget that is merely *usually* respected is not good enough
when the whole point is landing under a host's hard limit, so the encoder
constrains the rate rather than only requesting it.

Two refusals worth noting:

- **Never upscale.** A 720p source stays 720p.
- **Pass through when re-encoding would only lose quality** — source already
  small enough, already low-bitrate, already H.264 or HEVC. Re-encoding an
  already-web-sized clip trades quality for nothing.

### Apple Silicon

Minimum target is macOS 26 on arm64. No universal binaries, no `#available`
guards.

Scaling uses `VTPixelTransferSession` rather than Core Image: the decoder emits
biplanar `420v`, and CIContext has to convert to RGB and back even on the GPU,
while `VTPixelTransferSession` operates on those buffers natively. `420v` runs
end to end — reader output, adaptor attributes, encoder input — so no pixel
format conversion sneaks in anywhere. Destination buffers come from the
adaptor's pool rather than being allocated per frame.

Hardware encoding is *required*, not hoped for. `VTCopyVideoEncoderList` lists
software H.264 and HEVC encoders alongside the hardware ones, so silently
falling back is a real risk;
`kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder` is passed
through `AVVideoEncoderSpecificationKey`, but only after confirming a hardware
encoder exists for that codec — `writer.canApply(outputSettings:)` does not
validate that dictionary, so a bad spec fails at `startWriting()` instead.

Measured on a 17-clip synthetic note (worst-case noise, which defeats both intra
prediction and motion estimation): **437 MB → 156 MB in 24.7 seconds.** Real
footage compresses far better — the 4K sample above went 162.3 MB → 23.3 MB.

### Progress

Videos dominate export time and vary by three orders of magnitude in size, so
the progress bar is **weighted by source bytes**, not by item count. Within a
single video, the transcoder reports the last presentation timestamp over
duration. The result is a bar that moves smoothly and honestly, plus a detail
line naming the current file and its before/after size.

## The site model

The goal was `alecs-notes.example.com/workout-1/`, `/workout-2/`, … under one
domain.

A **site root** is a folder on disk holding one subdirectory per published note,
plus a generated `index.html` listing them. The user picks it once. Exporting a
note writes into `<root>/<slug>/`; publishing uploads the whole root.

The local folder is the **source of truth**, not the remote host. That means the
user can inspect it, back it up, and hand it to any host — including by hand.
Re-uploading everything each time sounds wasteful but is not: Cloudflare's upload
API is content-addressed, so unchanged notes cost a hash comparison and zero
bytes. Republishing one note out of twenty uploads only that note.

Slugs are stable. A note's slug is recorded against its Notes identifier in a
dot-prefixed sidecar, so re-exporting a note overwrites `/workout-1/` rather
than accumulating `/workout-1-2/`, `/workout-1-3/` beside it. Published URLs
don't rot.

## Providers

```swift
public protocol SitePublisher: Sendable {
    static var providerID: String { get }
    static var displayName: String { get }
    static var capabilities: ProviderCapabilities { get }
    func validateCredentials() async throws -> String
    func publish(siteRoot: URL, progress: ...) async throws -> PublishResult
}
```

`ProviderCapabilities` carries the per-file limit, file-count limit, and the
human text describing what credential to create and where. The UI renders
entirely from that — the settings screen has no Cloudflare-specific code, and
the per-file limit shown in the export sheet comes from the selected provider
rather than a hardcoded 25 MB.

Adding Vercel, Netlify, or an S3 bucket is: write a `SitePublisher` in the kit,
append one `ProviderDescriptor` to `ProviderRegistry.all`. No changes to the
settings screen, the export sheet, or the model.

Progress is reported in **bytes**, not files, for the same reason as the export
bar: one 20 MB video and ten 4 KB files are not eleven equal units.

## Secrets

**No secret is embedded in this app.** It is open source and distributed as a
binary; any secret compiled into it is a published secret. There is no client
secret, no app key, no service account.

There *is* now a public OAuth **client ID**, and that is not a contradiction —
see [Signing in](#signing-in) below. The rule is about secrets, and a client ID
is a public identifier by design.

Credentials are stored in the **macOS Keychain**
(`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlocked`, service
`com.alecf.notes-to-web`) — never in `UserDefaults`, never in a plist, never in
a log line, never in an error message. Two accounts are used: the provider ID
holds a pasted API token, and `cloudflare-workers.oauth` holds the JSON-encoded
OAuth tokens. `Preferences` holds only non-sensitive values: account ID, site
name, quality settings, and which of the two routes is in use.

Once stored, a token is never displayed again. The settings field shows
placeholder bullets, so a stored token cannot be read off the screen or captured
in a screenshot. OAuth tokens are never rendered at all — they live behind the
session actor and only ever become an `Authorization` header.

## Signing in

Two routes, because they fail for different people.

### The pre-filled token link

The original flow asked the user to find *Account → Workers Scripts → Edit* in a
dropdown of well over a hundred permissions. That search was the single most
intimidating step, and it turns out to be entirely avoidable: Cloudflare
documents a template URL format that pre-fills the token form.

```
https://dash.cloudflare.com/profile/api-tokens
  ?permissionGroupKeys=[{"key":"workers_scripts","type":"edit"},
                        {"key":"account_settings","type":"read"}]
  &accountId=*&zoneId=all&name=Notes%20to%20Web
```

Cloudflare publishes this exact pairing as its own "Workers scripts only"
template, so the format is not reverse-engineered. `account_settings: read` is
added on the theory that it is what `GET /accounts` needs — unverified, chosen
because Cloudflare's *Edit Cloudflare Workers* template bundles it, and harmless
if wrong because account discovery already treats a refusal as "ask the user".

Five steps became four, and none of them is a search.

### OAuth, which is possible now and was not before

Cloudflare shipped **self-managed OAuth clients in June 2026**, after the first
version of this document was written. That changes the calculus: a public client
using **PKCE** needs no client secret, so the "nothing embedded" rule survives.

The evidence, all first-party:

- `dash.cloudflare.com/.well-known/openid-configuration` advertises
  `code_challenge_methods_supported: ["plain", "S256"]` and
  `token_endpoint_auth_methods_supported` including `"none"`.
- Cloudflare's own docs: "Your application generates a unique code verifier and
  code challenge for every login request instead of using a static client secret."
- Wrangler already does this, redirecting to `http://localhost:8976/oauth/callback`
  with a client ID committed to a public repository — which is also the practical
  proof that Cloudflare will redirect to loopback.

The flow is the standard one: bind a loopback listener on **port 9787**, open the
browser to `/oauth2/auth` with a `state` and an S256 challenge, catch the
redirect, exchange the code plus verifier at `/oauth2/token`, store the tokens.

Three decisions worth recording:

- **Loopback, not a custom URL scheme.** RFC 8252 prefers it, and the reason is
  concrete: any app can register `notestoweb://` and steal the callback, but only
  one process can hold a port. The literal `127.0.0.1` is used rather than
  `localhost`, because a name can resolve somewhere else.
- **The port is fixed, not ephemeral.** Cloudflare matches `redirect_uri` against
  the exact strings registered on the client, so an OS-assigned port could never
  match.
- **`allowLocalEndpointReuse` is off.** With it on, a second `NWListener` binds a
  port the first already holds, so a stale sign-in could silently take a newer
  one's callback. A clash has to be an error. This was caught by a test that
  expected a conflict and did not get one.

`CloudflareAPI` asks for its bearer token **per request** rather than holding one,
which is what lets a refresh land between two requests of a publish that takes
minutes. Refreshes are serialised through an actor: two concurrent refreshes
would each spend the refresh token, and Cloudflare is free to invalidate the
loser.

A refresh failure only clears the stored tokens when Cloudflare says
`invalid_grant`. An outage or a flaky network leaves them alone — otherwise every
hiccup becomes a re-sign-in.

**Not yet verified against the live service.** No client is registered, so
`bakedInClientID` is empty and the button is hidden; the app falls back to the
token flow, which is fully working. Two things need confirming before that
changes: the real scope names (the constants are a best guess from Cloudflare's
lone `workers-platform.read` example — the authoritative list comes from
`GET /oauth/scopes`), and whether a loopback redirect URL is accepted at client
registration. Making a client's visibility **public** is permanent and requires
domain verification, so testing with a private client first is worth the detour.

### What the user needs to create

For Cloudflare, in the dashboard:

1. **Account ID** — Workers & Pages → Overview, right-hand sidebar. Not secret.
2. **API token** — My Profile → API Tokens → Create Token, with permission to
   edit Workers Scripts on that account. This is the secret. It goes in the
   Keychain and can be revoked from the same page at any time.

The app validates the token before storing it, so a typo fails at "Save & Test"
rather than partway through a 50 MB upload.

### Discovering the account instead of asking for it

Three inputs — account ID, site name, token — is two too many. The site name is
the app's to propose, and the account ID should be discovered from the token.
`CloudflarePublisher.discoverAccounts` does that, but it cannot be relied on:

**Cloudflare does not document which permission `GET /client/v4/accounts`
requires**, and no page in the API reference or the permissions reference states
it. The evidence says a token holding only *Account → Workers Scripts → Edit*
will not be able to enumerate accounts:

- Cloudflare's own *Edit Cloudflare Workers* token template bundles *Account
  Settings: Read*, *User Details: Read* and *User Memberships: Read* next to the
  Workers permission — which it would not need to do if Workers alone sufficed.
- Wrangler discovers the account through `GET /memberships`, and a workers-sdk
  maintainer says that call needs *All users → Memberships: Read*, "which is not
  added to the normal Workers Edit API token template" (workers-sdk#1873).
  Narrow tokens get 403 code 9109 there (workers-sdk#1422).
- The documented advice to set `CLOUDFLARE_ACCOUNT_ID` exists precisely to skip
  a discovery step that often cannot run.

None of this was reproducible without a live narrow token, so nothing is
assumed. Discovery tries `/accounts`, then `/memberships`, and **returns an
empty list rather than an error when both refuse**. Empty means "ask the user
for an ID", and the token-creation instructions name *User → Memberships → Read*
as an optional extra that removes the question. A refusal here is never reported
as a bad token: `/user/tokens/verify` runs first, and only that endpoint's
failure means the credential is at fault.

Site listing is the easy half: `GET /accounts/{id}/workers/scripts` returns
`has_assets` per script, documented as "Whether a Worker contains assets", so
the app can tell its own sites from the user's unrelated Workers without a
second request per script. When the field is missing the site is treated as not
asset-serving, which is the safe direction: it is never claimed that a code
Worker is one of ours and therefore safe to overwrite.

## Non-goals for now

- **R2 for oversized files.** Worth doing when a clip is genuinely too long to
  fit 25 MiB even compressed. The plan already detects that case and names the
  file; routing it to R2 is a later provider, not a blocker.
- **Custom domains.** `*.workers.dev` first.
- **Deleting remote notes.** Removing a note from the site root and
  republishing is the current story.

## A note on terms of service

GitHub Pages prohibits commercial use; Vercel's Hobby tier does too. For
personal notes this is fine, but the app should say so plainly next to any
provider it offers rather than let a user find out later. Cloudflare's free tier
has no such restriction.
