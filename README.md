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
- **Downloads** — videos kept in a `Downloads` folder on the device and played from the file
  wherever they turn up in the app, with no network at all. Needs a resolver, and
  [one is included](#one-is-included) — see [Downloads](#downloads)
- **Background playback** — the audio carries on when the app is backgrounded or the screen
  locks, with title, artwork, scrubber and transport on the lock screen and in Control Centre
- **Settings** — Google sign-in, API key, library counts, what is left of the day's API quota,
  and a reset that puts the device back to a fresh install

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

**Promoted videos don't make it through.** A sponsored card carries an ordinary watch link, so the
link says nothing; the slot it sits in does. YouTube wraps its ad units in custom elements named
for what they are — `ytm-promoted-video-renderer`, `ytd-ad-slot-renderer` — and element names are
the durable part of that page, where class names are minified and churn. The reader skips any link
under one of those, and YouTube's own page hides them with a stylesheet of the same names.

Be clear about what this is. It is outside what YouTube's terms allow an app to do: the default
rendering reads a rendered page, which is automated extraction, where showing the page is only
browsing — and hiding the adverts on that page is a further step again. The risk sits on your Google account, not on anyone else. It is also brittle by nature —
it leans on `watch?v=` links surviving a redesign, which is the most stable thing on the page but
not a contract. Nothing here runs until you sign in: no session, no third segment, and signing out
forgets both. The one thing the app misrepresents is its user-agent string, because `WKWebView`
otherwise sends one Google refuses to accept a sign-in from.

**The bell, and the notifications behind it.** Which channels you gave the bell to is not in the
Data API: a subscription resource carries `contentDetails.activityType` — a leftover from when the
choice was uploads-or-everything — and nothing that maps to the bell's three settings. Neither is
there a push channel for a personal account, so real-time notifications are out at any price; the
app polls instead. What the web session can reach is the account's own notification inbox, and
**Settings → Notifications → Import YouTube's Notifications** reads it: the notifications go into
the app's inbox, already read, and the channels behind them become the app's per-channel opt-ins.
A channel reaches that inbox only because its bell is on, which is what makes the list right — with
the one gap that a channel which hasn't uploaded lately isn't in it to be found.

**Passkeys don't work for this sign-in.** `WKWebView` has no WebAuthn support at all — only Safari
and `ASWebAuthenticationSession` do — so the app takes WebAuthn off the page rather than let Google
offer a passkey that can never complete. Use a password and 2FA; an account with no password left on
it can't open this session. The Google OAuth sign-in above is unaffected: it runs in
`ASWebAuthenticationSession`, which is a real Safari session.

This does not touch playback, which stays on the official embed and inside the Terms.

## Downloads

Downloaded videos land in a **`Downloads` folder** in the app's documents — which the Files app
shows under *Better YouTube*, so they are real files you can see, copy out and delete — and the
app plays them **from the file wherever the video appears**. Tap something in Watch Later, in your
history, in a search result or in the up-next queue, and if it has been downloaded it plays from
disk. Nothing has to be opened from the Downloads screen, and nothing is different about it when
it does: the same mini player, the same lock-screen controls, the same landscape full screen.

**Download** sits in the long-press menu on every video in the app, and as a pill in the player.
There is one Downloads screen, under Library, for the folder as a whole.

What makes it dependable is that the app isn't the one doing the work. Transfers go through a
**background `URLSession`**, so iOS owns them: they carry on with the app backgrounded, survive
the app being killed, and relaunch it when they finish. An interrupted one leaves resume data and
carries on from the bytes it already has rather than starting again. The queue runs two at a time,
retries a dropped connection twice, and writes its state to a manifest as it goes — so a download
is never quietly lost, only ever finished, paused or failed with a reason and a Try Again button.

Settings holds a quality, a Wi-Fi-only switch, a ceiling on the folder's size, and what it weighs
today. Downloads are excluded from iCloud backups: they are the largest thing this app will ever
write and none of it is worth backing up.

### The part the app can't do: a resolver

**No download service ships with the app, and none is suggested.** Playback goes through YouTube's
own embed, which never exposes a media file, so the app has no way to reach one by itself. To
download anything you point **Settings → Downloads** at a resolver **you run**, and the app treats
it as an ordinary HTTP API.

That is a deliberate line rather than an omission. Getting at YouTube's media means defeating the
rotating signature cipher and throttling parameter that exist to stop exactly that, which is
circumvention — and it is also the code that breaks every few weeks when Google rotates them. A
download button built on it works the week it ships and then rots silently, which is the opposite
of what a download is for. A resolver of your own, on the other hand, is one you can fix the day it
breaks; a stranger's public instance is one that goes dark, throttles you, or keeps a record of
what you watch.

Two shapes work, told apart by the address alone:

| Address | What the app does |
| --- | --- |
| Contains `{id}`, `{videoId}` or `{url}` | Fills it in and fetches it as the media file directly. `https://box.local/yt/{id}.mp4` is a complete configuration. |
| Anything else | `POST`s `{"url", "videoId", "quality", "maxHeight"}` and reads a media link out of the reply. |

The request says the wanted height under every name the common resolvers read it by
(`quality`, `videoQuality`, `maxHeight`), since they ignore fields they don't know and the
alternative is a quality setting that is silently disregarded. The reply is read just as
generously: `url`, `downloadUrl`, `link`, `media`, a `urls` or `tunnel` array, or the first entry
of `formats`, `streams` or `medias`, one level inside `data` or `result` if that is where they
sit. A reply that says it failed — `status: "error"`, or an `error` of its own — is reported in
the service's own words rather than as a generic failure.

Two shapes are refused on purpose. A reply carrying the video and the audio as **separate
streams** for the client to join is one the app can't use — it plays a single file — and taking
the first of the two would download a silent video rather than fail, so it says what happened and
what to change instead. And a media link that isn't absolute `http(s)` is dropped at the resolver
rather than handed to the downloader, which is a worse place to find out about it.

A token can be set for a service that isn't open to the internet. One typed with its own scheme
(`Api-Key abc123`) is sent as it stands; a bare one is sent as `Bearer`.

### One is included

`resolver/` is a working one: about 300 lines of Python standard library around **yt-dlp**, with a
`docker compose up` and a test suite that runs offline. That split is deliberate — yt-dlp is the
only part that needs keeping current, and it is maintained by people who do it full time, so the
container refreshes it on every start.

It answers in two ways, and the difference is what it costs you to run. When YouTube offers the
wanted height **already joined** — in practice 360p, sometimes 720p — the answer is YouTube's own
CDN URL and the phone fetches it from Google: this server moves no video at all. Above that
YouTube keeps video and audio apart and the app plays a single file, so the answer is a link back
to the resolver, which re-resolves and pipes both through ffmpeg into a fragmented MP4 as it goes.
Nothing is staged on disk, and `ALLOW_MUX=0` refuses that path entirely if you would rather never
carry a byte of video. Details in [`resolver/README.md`](resolver/README.md).

Other resolvers fit too: a self-hosted [**cobalt**](https://github.com/imputnet/cobalt), whose
`POST /` answers `{"status": "tunnel", "url", "filename"}`, drops straight in — set its `API_URL`
to the address you reach it on, or it hands back links pointing at its own localhost.

### Setting one up on somebody else's phone

Typing a URL into a phone is the worst part of this, so it can be skipped. **Settings → Downloads
→ Share Setup** turns the current configuration into a `betteryoutube://` link and a QR code:
point another phone's camera at it and it is configured. The access token is left out unless you
ask for it, because a QR code gets photographed and forwarded far more casually than a password.

A link is never applied on its own. Opening one shows which host it points at, says that every
download will go through it, and waits — a link is something anyone can send you, and accepting
one quietly would let a stranger route your downloads through their server.

Be clear about what this is, the same way the home feed above is. Downloading a video is outside
what YouTube's terms allow, whoever fetches it; keeping a personal copy of something you can
already watch is the ordinary case for it, and the risk sits on your account and your resolver,
not on anyone else. Nothing here runs until you fill that field in: no service, no Download in any
menu, and the Downloads screen says so rather than offering a button that can't work.

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
   - **Tick the YouTube permission on the consent screen.** Google's consent screen has a tick box
     per sensitive scope, and leaving it unticked still issues a valid token — one that 403s on
     every request. The app checks what Google actually granted (the `scope` on the token
     response) rather than what it asked for, and refuses a sign-in that came back without it,
     so this fails loudly at the sheet instead of quietly a moment later.
   - The flow is OAuth 2.0 with PKCE via `ASWebAuthenticationSession`, so no client secret is
     needed and no URL scheme has to be registered manually. That also rules out **passkeys**:
     iOS only offers them in Safari itself, and the callback scheme is the reversed client ID —
     entered at runtime, so it can't be declared in `Info.plist` and the flow can't move to
     Safari. Sign in to Google in Safari with your passkey instead; the session is not ephemeral,
     so the sheet borrows those cookies and asks for nothing.
   - Scope requested: `https://www.googleapis.com/auth/youtube` — read/write, because the app
     creates and edits its own Watch Later playlist. A token granted for an earlier, narrower scope
     can't be widened in place, so the app drops it and asks you to sign in once more when the
     scope changes. Tokens are stored in the iOS keychain; the API key lives in `UserDefaults`.

## Project structure

```
resolver/                        A yt-dlp resolver: server.py, Dockerfile, compose, tests
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
    DownloadStore.swift          The Downloads folder, its manifest and what is in it
    DownloadService.swift        The configured resolver, and reading its reply
    DownloadManager.swift        The background download queue
    LocalPlayback.swift          AVPlayer half of the player, for downloaded files
    DownloadConfigLink.swift     betteryoutube:// setup links, and their QR codes
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
- Streaming playback uses the YouTube IFrame embed rather than extracting stream URLs. The app
  never resolves a media URL itself — downloading goes through a resolver you configure and run,
  and does nothing at all until you do. See [Downloads](#downloads).
