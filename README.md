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
- **Video detail** — stats, expandable description, comments, share sheet, and a thumbs-up that
  is the real like on your YouTube account (the heart beside it is this device's own favourites)
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
| OAuth 2.0 sign-in | An iOS OAuth client ID | Your subscriptions, your playlists, your liked videos, your channel, liking a video, and the app's own Watch Later playlist |

**Not available at any level:** the account's **Watch Later** (`WL`) and **watch history** (`HL`)
playlists — Google removed API access to both in 2016 — and the personalized home feed. No scope
reopens them, and they are absent from the Data Portability API's YouTube export too.
**Recommendations** went the same way: `activities.list?home=true` in 2016 and
`search.list?relatedToVideoId` in August 2023, so no endpoint returns YouTube's suggestions
either. What the app does instead is under [Recommendations](#recommendations).

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
- `videos.list`, `channels.list`, `playlistItems.list`, `subscriptions.list`, `commentThreads.list`,
  `videos.getRating` — **1 unit**
- `playlists.insert`, `playlistItems.insert`, `playlistItems.delete`, `videos.rate` — **50 units**

Lists longer than 50 come back a page at a time, and the app follows the `nextPageToken` until it
has them all — so a 300-channel subscription list is six calls, not one truncated at fifty.

Because of that, channel uploads are read through the channel's *uploads playlist*
(`playlistItems.list`, 1 unit) rather than a channel search (100 units), and search results are
enriched with a single batched `videos.list` call. Only the search box spends 100-unit requests.

Settings shows what is left of the day as a bar, with a breakdown of where the units went. No
endpoint reports the remaining quota, so the app prices each call from the table above as it goes
out and keeps the tally itself: it counts what *this device* spent, while the allowance belongs to
the Cloud project behind the API key, so anything else using that key spends from the same pot
without showing up. The count rolls over at midnight Pacific time, which is when Google refills it.

## Recommendations

YouTube's own home feed is not open to apps, and neither are related videos. The two things the
Data API still publishes are the **most-popular chart** — per region and per category — and the
uploads of any channel you name, so **For You** is those two woven together: YouTube's chart for
the categories you actually watch, alternating with fresh uploads from the channels you watch
most. Half of it is YouTube's own ranking; half is the app's, and the foot of the feed says so.
Signed out, or on a fresh install with nothing to go on, it is simply YouTube's chart.

The player carries YouTube's real suggestions too: the embed runs with `rel=1`, so its end screen is
YouTube's own related videos rather than more from the same channel.

### Your actual home feed, off the books

Your personalized feed does exist in one place — YouTube's own web page, served to a signed-in
session. **Settings → YouTube Home** signs you in to `youtube.com` in a web view and keeps that
session's cookies on the device, in a data store of its own. Home then grows a third segment,
**YouTube**, which reads the *order* of the videos on your home page and fetches everything it
displays about them through the Data API — about one quota unit a refresh. What YouTube contributes
is the ranking, which is the part no endpoint sells; what you see comes from the official API. A
setting switches between the app's cards and YouTube's own page, and on that page a tap opens the
video in the app's player rather than YouTube's.

Be clear about what this is. It is outside what YouTube's terms allow an app to do: the default
rendering reads a rendered page, which is automated extraction, where showing the page is only
browsing. The risk sits on your Google account, not on anyone else. It is also brittle by nature —
it leans on `watch?v=` links surviving a redesign, which is the most stable thing on the page but
not a contract. Nothing here runs until you sign in: no session, no third segment, and signing out
forgets both. The one thing the app misrepresents is its user-agent string, because `WKWebView`
otherwise sends one Google refuses to accept a sign-in from.

This does not touch playback, which stays on the official embed and inside the Terms.

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
    QuotaTracker.swift           The day's quota spending, counted call by call
    YouTubeWebSession.swift      Optional youtube.com web session + home-feed reader
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
