# Better-YouTube

An unofficial YouTube client for iOS, built with SwiftUI and designed to feel like a native Apple
app (Apple Music-style shelves, artwork cards, inset-grouped library, context menus, share sheets).

## Features

- **Home** — featured hero card, "From Your Subscriptions", "Trending Now" and "Continue Watching"
  carousels
- **Search** — debounced search for videos and channels, recent searches, browse categories
- **Playback** — the official YouTube embedded player (WKWebView), so playback stays within
  YouTube's Terms of Service. Turning the phone on its side hands the video to iOS's own
  full-screen presentation — the system's controls, over the app — and turning it back puts the
  player where it was
- **Video detail** — stats, expandable description, comments, share sheet, quick actions
- **Channels** — profile header plus latest uploads
- **Library** —
  - *Signed in with Google*: your subscriptions, playlists and liked videos
  - *On this device*: favorites, watch later and watch history
- **Settings** — Google sign-in, API key, library counts, and what is left of the day's API
  quota

## What the YouTube API can and cannot do

The app talks to the public **YouTube Data API v3**. Two levels of access exist:

| Access | Needs | Gives you |
| --- | --- | --- |
| API key | A key from the Google Cloud Console | Trending, search, video details, channels, comments, public playlists |
| OAuth 2.0 sign-in | An iOS OAuth client ID | Your subscriptions, your playlists, your liked videos, your channel, and the app's own Watch Later playlist |

**Not available at any level:** the account's **Watch Later** (`WL`) and **watch history** (`HL`)
playlists — Google removed API access to both in 2016 — and the personalized home feed. No scope
reopens them, and they are absent from the Data Portability API's YouTube export too.

Watch history therefore stays on the device. **Watch Later works around it**: rather than reading
`WL`, the app creates and manages a private playlist of its own ("Watch Later — Better YouTube")
through the ordinary playlist endpoints. It is a real playlist, so it syncs across your devices and
shows up in the YouTube app — which the on-device list never did. Signed out, the on-device list is
still what you get. The catch is quota: `playlistItems.insert` and `.delete` cost **50 units** each,
so about 200 changes a day.

Whatever your real Watch Later already holds can be carried over once, through **Google Takeout**:
export *YouTube and YouTube Music → playlists*, unzip, and import the CSV from Settings. The
importer only looks for video IDs, so it works for any playlist in the export, whatever Google has
renamed the files to this year (Watch Later comes out as `Vidéos de Watch later.csv`, in the
account's own language). An import takes the **60 most recently added** — decided by the add date
the export carries, not by the order of the lines — and reports how many older ones it left behind.
Imported videos land on the device; sending them up to the playlist is a separate, explicit step,
because that part is what costs quota.

### Quota

The default quota is **10,000 units per day**, and endpoints are not priced equally:

- `search.list` — **100 units** per call
- `videos.list`, `channels.list`, `playlistItems.list`, `subscriptions.list`, `commentThreads.list` — **1 unit**
- `playlists.insert`, `playlistItems.insert`, `playlistItems.delete` — **50 units**

Settings shows what is left of the day as a bar, with a breakdown of where the units went. No
endpoint reports the remaining quota, so the app prices each call from the table above as it goes
out and keeps the tally itself: it counts what *this device* spent, while the allowance belongs to
the Cloud project behind the API key, so anything else using that key spends from the same pot
without showing up. The count rolls over at midnight Pacific time, which is when Google refills it.

Because of that, channel uploads are read through the channel's *uploads playlist*
(`playlistItems.list`, 1 unit) rather than a channel search (100 units), and search results are
enriched with a single batched `videos.list` call. Only the search box spends 100-unit requests.

## Getting started

1. Open `BetterYouTube/BetterYouTube.xcodeproj` in Xcode 26+ and run on an iOS 26+ simulator or device.
2. **API key** (required for browsing): in the Google Cloud Console, enable the *YouTube Data API v3*
   and create an **API key** credential. Paste it on first launch or in Settings.
3. **Google sign-in** (optional, for your own library): in the same project, create an **OAuth 2.0
   client ID** of type **iOS** with the app's bundle identifier
   (`com.atomtoto.BetterYouTube`, or your own). Paste the client ID in Settings, then tap
   *Sign in with Google*.
   - **Add yourself as a test user**, or sign-in fails with `Error 403: access_denied`. In
     *Google Auth Platform → Audience*, with publishing status **Testing**, only the accounts listed
     under *Test users* may grant consent — add the Google account you sign in with. Alternatively
     switch the app to **In production** (with the sensitive `youtube` scope you'll then see
     an "unverified app" interstitial you can pass via *Advanced*).
   - Note: while in Testing, Google expires refresh tokens after **7 days**, so you'll be asked to
     sign in again about once a week. Publishing the app removes that limit.
   - The flow is OAuth 2.0 with PKCE via `ASWebAuthenticationSession`, so no client secret is
     needed and no URL scheme has to be registered manually.
   - Scope requested: `https://www.googleapis.com/auth/youtube` — read/write, because the app
     creates and edits its own Watch Later playlist. A token granted for an earlier, narrower scope
     can't be widened in place, so the app drops it and asks you to sign in once more when the
     scope changes. Tokens are stored in the iOS keychain; the API key lives in `UserDefaults`.

## Project structure

```
BetterYouTube/
  BetterYouTube.xcodeproj/       Xcode project (single iOS app target, iOS 26+)
  BetterYouTube/
    BetterYouTubeApp.swift       App entry point
    Theme.swift                  Design tokens + shared artwork/avatar/section components
    Models.swift                 Domain models and YouTube API decoding
    YouTubeAPIService.swift      API client (actor) with OAuth + API key support
    GoogleAuthService.swift      OAuth 2.0 PKCE sign-in, keychain token storage
    Persistence.swift            On-device library and recent searches
    Utilities.swift              Duration, count and relative-date formatters, Takeout CSV reader
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
