# Better-YouTube

An unofficial YouTube client for iOS, built with SwiftUI and designed to feel like a native Apple
app (Apple Music-style shelves, artwork cards, inset-grouped library, context menus, share sheets).

## Features

- **Home** — featured hero card, "From Your Subscriptions", "Trending Now" and "Continue Watching"
  carousels
- **Search** — debounced search for videos and channels, recent searches, browse categories
- **Playback** — the official YouTube embedded player (WKWebView), so playback stays within
  YouTube's Terms of Service
- **Video detail** — stats, expandable description, comments, share sheet, quick actions
- **Channels** — profile header plus latest uploads
- **Library** —
  - *Signed in with Google*: your subscriptions, playlists and liked videos
  - *On this device*: favorites, watch later and watch history
- **Settings** — Google sign-in, API key, library counts, quota guidance

## What the YouTube API can and cannot do

The app talks to the public **YouTube Data API v3**. Two levels of access exist:

| Access | Needs | Gives you |
| --- | --- | --- |
| API key | A key from the Google Cloud Console | Trending, search, video details, channels, comments, public playlists |
| OAuth 2.0 sign-in | An iOS OAuth client ID | Your subscriptions, your playlists, your liked videos, your channel |

**Not available at any level:** the account's **Watch Later** (`WL`) and **watch history** (`HL`)
playlists — Google removed API access to both in 2016 — and the personalized home feed. That's why
this app keeps its own on-device watch later / history lists.

### Quota

The default quota is **10,000 units per day**, and endpoints are not priced equally:

- `search.list` — **100 units** per call
- `videos.list`, `channels.list`, `playlistItems.list`, `subscriptions.list`, `commentThreads.list` — **1 unit**

Because of that, channel uploads are read through the channel's *uploads playlist*
(`playlistItems.list`, 1 unit) rather than a channel search (100 units), and search results are
enriched with a single batched `videos.list` call. Only the search box spends 100-unit requests.

## Getting started

1. Open `BetterYouTube/BetterYouTube.xcodeproj` in Xcode 15+ and run on an iOS 16+ simulator or device.
2. **API key** (required for browsing): in the Google Cloud Console, enable the *YouTube Data API v3*
   and create an **API key** credential. Paste it on first launch or in Settings.
3. **Google sign-in** (optional, for your own library): in the same project, create an **OAuth 2.0
   client ID** of type **iOS** with the app's bundle identifier
   (`com.atomtoto.BetterYouTube`, or your own). Paste the client ID in Settings, then tap
   *Sign in with Google*.
   - The flow is OAuth 2.0 with PKCE via `ASWebAuthenticationSession`, so no client secret is
     needed and no URL scheme has to be registered manually.
   - Scope requested: `youtube.readonly`. Tokens are stored in the iOS keychain; the API key lives
     in `UserDefaults`.

## Project structure

```
BetterYouTube/
  BetterYouTube.xcodeproj/       Xcode project (single iOS app target, iOS 16+)
  BetterYouTube/
    BetterYouTubeApp.swift       App entry point
    Theme.swift                  Design tokens + shared artwork/avatar/section components
    Models.swift                 Domain models and YouTube API decoding
    YouTubeAPIService.swift      API client (actor) with OAuth + API key support
    GoogleAuthService.swift      OAuth 2.0 PKCE sign-in, keychain token storage
    Persistence.swift            On-device library and recent searches
    Utilities.swift              Duration, count and relative-date formatters
    ViewModels/                  One @MainActor view model per screen
    Views/                       SwiftUI screens
    Views/Components/            Reusable cards and rows
```

## Continuous integration

`.github/workflows/ios-build.yml` builds the app with `xcodebuild` on a GitHub-hosted macOS runner
for every push and pull request, so compile errors surface without a local Mac.

## Notes

- Unofficial client; not affiliated with YouTube or Google.
- Playback uses the YouTube IFrame embed rather than extracting stream URLs.
