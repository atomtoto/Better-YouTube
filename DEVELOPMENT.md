# Development notes

What the code doesn't tell you: conventions, decisions, and what can only be checked on a device.
Setup is in the [README](README.md).

## iOS and macOS in one target

- Native SwiftUI on both (`SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`, `SDKROOT = auto`),
  not Catalyst.
- `Platform.swift` names what the two platforms spell differently (`PlatformImage`, the key window,
  colours, modifiers only one of them has). Use those names; keep an `#if os(macOS)` for a real
  difference (a phone turns on its side, a Mac app is never suspended), in the file that cares,
  with a comment.
- Settings is the same panes on both (`SettingsPane`); only the shell differs.
- The Mac build is sandboxed. That gives it a keychain access group of its own: tokens go to the
  data-protection keychain, not the login keychain, which would ask for the password.
- Every target uses the Swift 6 language mode.

## Signing

Before every build, both schemes run `scripts/detect-signing.sh`, which writes whether the team is
free to `Config/Detected.xcconfig`; `Config/Signing.xcconfig` then picks the entitlements
(`*-PersonalTeam`, `*-iCloud`, or the full iOS file with CarPlay). The Watch app, the tests and the
iCloud container (`iCloud.<bundle id>`) follow `BY_BUNDLE_ID`. At launch the app reads what it was
signed with (the Mac from its entitlements, an iPhone from its provisioning profile) and hides
iCloud sync when the build can't use it.

The entitlements use the development APNs environment: check the archive's distribution profile.
Every Mac variant keeps the App Sandbox entitlements.

## iCloud sync

- `CKSyncEngine`, custom zone **`BetterYouTubeLibrary`** in the private database. Record type
  **`LibraryEntry`**: `schemaVersion` (Int64, `1`) and `payload` (a JSON-encoded entry).
  Deterministic record IDs; a removal keeps a tombstone so a device coming back online doesn't
  resurrect it.
- Synced: favorites, the app's Watch Later, history, playback positions, mini player style and
  size. The latest playback checkpoint wins, backward seeks included. Everything else stays on the
  device: downloads, credentials, sessions, recent searches, quota, notifications.
- The Watch never talks to CloudKit; it gets the library from its iPhone through Watch Connectivity.
- Development saves create the schema; deploy it to production before TestFlight or the App Store.

**To check on two signed devices** (same Apple Account): additions and removals both ways, history
clearing, resume positions (pause on one, open on the other; backward seek; finishing; streaming vs
downloaded copy), changes made offline then reconnected, Sync Now, iCloud sign-out, turning sync
off, *Reset App* on one device (the other and the cloud keep the library), and the paired Watch.

## CarPlay

- `CarPlaySceneDelegate` is declared in the scene manifest, with `carplay-audio` and `carplay-video`
  entitlements. Apple must grant them for the app ID; regenerate the profile afterwards.
- On iOS 27, cars that advertise video get it through `CPPlaybackConfiguration`, with an H.264/AAC
  stream or AAC audio as a fallback. The app doesn't guess whether the car is parked: CarPlay decides.
- Connecting hands online playback to the native player; disconnecting keeps it going.

**To test**: CarPlay Simulator in Device Hub for the interface, the one in *Additional Tools for
Xcode* for video. Check the four tabs, an empty library, Now Playing and Up Next, seeking, queue
advance, unavailable streams, offline downloads, video-capable and audio-only cars, video
disallowed then allowed again, connecting while playing and while paused. Then in a real car with
a provisioned iPhone (lock, interruptions, reconnection).

## Downloads

- [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) is pinned at **0.4.9** and always called
  with `methods: [.local]`: its remote fallback is never used. A local failure never falls back to
  the server either.
- Media is fetched in 4 MiB ranges (YouTube refuses unbounded requests) in a background
  `URLSession`, two videos at a time. Each stage and byte offset is saved in the manifest, so
  transfers survive a relaunch. Tracks are joined with AVFoundation, without re-encoding.
- Extraction and assembly run in the app: they pause if iOS takes the background time away.
- **Server mode**: an address with `{id}`, `{videoId}` or `{url}` is fetched directly; anything else
  gets a `POST` of `{"url", "videoId", "quality", "maxHeight"}`, and the reply is read generously
  (`url`, `downloadUrl`, `link`, `urls`, `formats`…). Separate streams are refused. A token with its
  own scheme is sent as is; a bare one as `Bearer`.
- Setup links (`betteryoutube://`) are never applied without confirmation, and a shared QR code
  leaves the token out unless asked.

**Live download test** (off by default), from the macOS test command:

```sh
TEST_RUNNER_BETTERYOUTUBE_LIVE_DOWNLOAD=1 xcodebuild test … -only-testing:BetterYouTubeTests/LiveLocalDownloadTests
```

Keep the sandbox entitlements for it (don't pass `CODE_SIGN_ENTITLEMENTS=""`), or the system
download service fails with "Cannot create file". `TEST_RUNNER_BETTERYOUTUBE_LIVE_VIDEO` picks
another video. Background scheduling on a real iPhone is still unvalidated.

## youtube.com session

- Its cookies stay in a WebKit data store of its own: never read into Swift, logged or sent
  elsewhere. Watch Later and the home feed go through YouTube's internal website endpoints, inside
  that WebKit context.
- The home feed only takes the **order** of the `watch?v=` links from the page; everything shown
  comes from the Data API (about one unit a refresh).
- Ads are skipped by their custom element names (`ytm-promoted-video-renderer`,
  `ytd-ad-slot-renderer`), which last, unlike the minified class names.
- The user-agent is overridden because Google refuses a sign-in from `WKWebView`'s. WebAuthn is
  removed from the page so Google doesn't offer a passkey that can't complete.
- The bell settings aren't in the Data API. *Import YouTube's Notifications* reads the account's
  notification inbox instead; otherwise the app polls (at most every 30 minutes).

## Quota

| Call | Units |
| --- | --- |
| `search.list` | 100 |
| `videos.list`, `channels.list`, `playlistItems.list`, `subscriptions.list`, `commentThreads.list`, `videos.getRating` | 1 |
| `playlists.insert`, `playlistItems.insert`, `playlistItems.delete`, `videos.rate` | 50 |

Channel uploads come from the uploads playlist (1 unit), never a search (100); search results are
filled in with one batched `videos.list`. No endpoint reports what is left, so `QuotaTracker`
prices each call itself: it only sees this device, and resets at midnight Pacific.

## Apple Watch

The Watch can't stream: watchOS has no WebKit for the embed. *Download to Watch* asks the reachable
iPhone to resolve an M4A track, then the Watch fetches it in ranges over its own network;
*Transfer from iPhone* moves an existing MP4. Search uses the API key sent by the iPhone (an
OAuth-only setup has none). To check on a paired watch: transfers and background audio routing.

## Localization

Strings live in `Localizable.xcstrings`, `InfoPlist.xcstrings`, `AppShortcuts.xcstrings` (Siri
phrases) and the Watch's `Localizable.xcstrings`. French uses the informal *tu*. Write new text as
a literal in `Text`, `Label`, `Button`…, or `String(localized:)`. The test action is pinned to
English.

## No CI

The GitHub macOS runner's Swift compiler crashed on `HomeView.swift`, so the workflow was removed.
It is still in the history (`.github/workflows/build.yml`).
