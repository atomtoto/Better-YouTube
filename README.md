# Better-YouTube

An unofficial YouTube client for **iPhone, iPad, Mac, Apple Watch and CarPlay**, built with SwiftUI to
feel like a first-party Apple app. One target builds iOS and macOS (native, not Catalyst); a separate
Watch app handles library, search and offline audio.

## Features

- **Home** — *For You* (YouTube's charts for the categories you watch, mixed with new uploads from
  your most-watched channels), *Subscriptions*, and your real YouTube home feed with an optional
  youtube.com session
- **Search** — filters, recent searches, free suggestions; pasting a YouTube link opens it
- **Playback** — the official YouTube embed under native controls: chapters, captions, quality,
  speed, Picture in Picture, full screen, sleep timer, resume where you left off
- **Library** — subscriptions, playlists and likes from your Google account; favorites, Watch
  Later and history synced through iCloud
- **Downloads** — real files in a `Downloads` folder, played offline anywhere they appear in the app
- **Background playback** — keeps playing when the iPhone locks, with lock-screen controls
- **Shortcuts, Siri, Spotlight and Handoff**
- **Demo mode** — real videos, no account or key needed (`betteryoutube://demo`)
- **English and French** everywhere

## Getting started

Requires Xcode 27+, iOS 26+ / macOS 26+ / watchOS 26+.

1. Copy `BetterYouTube/Config/Local.xcconfig.example` to `Local.xcconfig` and put your Team ID in it.
   A free Apple account works; with one, also set `BY_BUNDLE_ID` to a bundle ID of your own.
2. Open `BetterYouTube/BetterYouTube.xcodeproj` and run on a simulator, a device or *My Mac*.
3. Connect YouTube, either way (or both — the key then handles public requests):
   - **Google sign-in** (recommended): in the Google Cloud Console,
     [enable the YouTube Data API v3](https://console.cloud.google.com/apis/library/youtube.googleapis.com)
     and [create an OAuth client ID](https://console.cloud.google.com/auth/clients) of type **iOS**
     with your bundle ID (it works for the Mac too). Paste the client ID in the app and sign in.
   - **API key**: [create one](https://console.cloud.google.com/apis/credentials) for public browsing
     without an account.
4. Optional: *Settings → YouTube Home* signs in to youtube.com for your real home feed and Watch Later.

**Avoid the weekly sign-in.** While the OAuth app is in *Testing*, Google expires tokens after 7 days
(and only accounts listed as test users can sign in). To publish it, fill the
[Branding](https://console.cloud.google.com/auth/branding) page with the project's own pages —
leave the logo empty — then click *Publish app* under *Audience*. No verification is needed for
personal use; pass the "unverified app" screen via *Advanced*. On the consent screen, **tick the
YouTube permission**, or the sign-in is refused.

| Branding field | Value |
| --- | --- |
| Home page | `https://atomtoto.github.io/Better-YouTube/` |
| Privacy policy | `https://atomtoto.github.io/Better-YouTube/privacy.html` |
| Terms of service | `https://atomtoto.github.io/Better-YouTube/terms.html` |
| Authorized domain | `atomtoto.github.io` |

### What your Apple account unlocks

| Team | iCloud sync | CarPlay |
| --- | --- | --- |
| Free (Personal Team) | no — builds expire after 7 days | no |
| Paid | yes, detected automatically | no |
| Paid, CarPlay entitlements granted by Apple | yes | `BY_CARPLAY = YES` in `Local.xcconfig` |

For iCloud, deploy the CloudKit schema to production in the
[CloudKit Console](https://icloud.developer.apple.com/) before shipping a TestFlight or App Store build.

## Downloads

By default, videos are downloaded and assembled **on the device** with
[YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) — nothing to install. You can instead point
*Settings → Downloads* at your own server: [`resolver/`](resolver/README.md) is a small yt-dlp
resolver to run at home with `docker compose up -d`.

## Limits

- **The public API has no Watch Later, history, home feed or related videos.** The optional
  youtube.com session fills that gap by reading YouTube's website — outside YouTube's terms and
  liable to break. Nothing runs until you sign in there.
- **Quota**: 10,000 units a day; a search costs 100, most reads 1. *Settings* shows what is left.
- **Passkeys** don't work for the youtube.com sign-in (no WebAuthn in `WKWebView`): use a password.
- Downloading videos is outside YouTube's terms too; playback itself stays on the official embed.

## Development

```sh
cd BetterYouTube
xcodebuild test -project BetterYouTube.xcodeproj -scheme BetterYouTube -destination "platform=macOS"
```

- `scripts/check-localizations.py` fails when a string has no French translation.
- `scripts/build-demo-catalog.py` rebuilds the demo catalogue.
- There is no CI: build and test on a Mac.

Conventions, design decisions and on-device checks are in [DEVELOPMENT.md](DEVELOPMENT.md).

Unofficial client; not affiliated with YouTube or Google.
