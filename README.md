# Better-YouTube

An unofficial YouTube client for **iOS and macOS**, built with SwiftUI and designed to feel like a
native Apple app (Apple Music-style shelves, artwork cards, inset-grouped library, context menus,
share sheets).

One target builds both. The phone gets a tab bar, a docked player over it and a video that goes
full screen when you turn the phone on its side; the Mac gets a sidebar, a menu bar with keyboard
shortcuts and a window. Everything between those two — the API client, the player, the download
queue, the on-device library — is the same code. See [Running on a Mac](#running-on-a-mac).

## Features

- **Home** — featured hero card, "From Your Subscriptions", "Trending Now" and "Continue Watching"
  carousels
- **Search** — debounced search for videos and channels, recent searches, browse categories
- **Playback** — the official YouTube embedded player (WKWebView), so playback stays within
  YouTube's Terms of Service. Turning the phone on its side hands the video to iOS's own
  full-screen presentation — the system's controls, over the app — and turning it back puts the
  player where it was. On a Mac, ⇧⌘F fills the window instead
- **Video detail** — stats, expandable description, comments, share sheet, and a thumbs-up that
  is the real like on your YouTube account (the heart beside it is this device's own favourites)
- **Channels** — profile header plus latest uploads
- **Library** —
  - *Signed in with Google*: your subscriptions, playlists and liked videos
  - *On this device*: favorites, watch later and watch history
- **Downloads** — videos kept in a `Downloads` folder on the device and played from the file
  wherever they turn up in the app, with no network at all. Downloads run directly on the device;
  a self-hosted resolver remains optional — see [Downloads](#downloads)
- **Background playback** — the audio carries on when the app is backgrounded or the screen
  locks, with title, artwork, scrubber and transport on the lock screen and in Control Centre
  (on a Mac: the media widget in Control Centre and the keyboard's play/pause key)
- **Settings** — Google sign-in, API key, library counts, what is left of the day's API quota,
  and a reset that puts the device back to a fresh install

## What the YouTube API can and cannot do

The app talks to the public **YouTube Data API v3**. Two levels of access exist:

| Access | Needs | Gives you |
| --- | --- | --- |
| API key (optional) | A key from the Google Cloud Console | Public browsing without signing in: trending, search, video details, channels, comments, public playlists |
| OAuth 2.0 sign-in (recommended) | An iOS OAuth client ID and a Google sign-in | Public browsing plus your subscriptions, custom playlists, liked videos, channel, and account actions |

One of these is enough for Data API browsing. When both are configured, public requests use the
API key and account requests use OAuth. The separate youtube.com sign-in for **YouTube Home** is
optional; it supplies the real personalized feed and Watch Later, which OAuth cannot access.

**Not available through the public Data API:** the account's **Watch Later** (`WL`) and **watch history** (`HL`)
playlists — Google removed API access to both in 2016 — and the personalized home feed. No scope
reopens them, and they are absent from the Data Portability API's YouTube export too.
**Recommendations** went the same way: `activities.list?home=true` in 2016 and
`search.list?relatedToVideoId` in August 2023, so no endpoint returns YouTube's suggestions
either. What the app does instead is under [Recommendations](#recommendations).

Watch history stays on the device. With **Settings → YouTube Home → youtube.com** connected,
**Watch Later uses the account's real `WL` playlist**, including reads, additions and removals.
Requests run inside the signed-in website's WebKit context; authentication cookie values are
not returned to Swift, persisted separately, logged or sent to another service. This uses
YouTube's internal website endpoints, not a supported public API, and may break when YouTube
changes them. Pagination and server confirmation are checked; failures never silently save to
a different list. Live account behavior still needs verification on a signed-in device.

Without a web session, Watch Later stays on the device. The app no longer discovers, creates or
writes to the former substitute playlist. A stale stored identifier is discarded on startup;
the remote playlist itself remains in the user's account until they choose to delete it.

Notifications offer **Watch Later** on a leading swipe. Long-press menus on videos, including
notifications, offer **Add to Playlist…**, with a native picker for custom playlists from the
Google OAuth account connected in Settings. This account can differ from the youtube.com account.
Custom playlist selection is deliberately absent from swipe actions.

Any playlist exported through **Google Takeout** can be imported:
export *YouTube and YouTube Music → playlists*, unzip, and import the CSV from Settings. The
importer only looks for video IDs, so it works for any playlist in the export, whatever Google has
renamed the files to this year (Watch Later comes out as `Vidéos de Watch later.csv`, in the
account's own language). An import takes the **60 most recently added** — decided by the add date
the export carries, not by the order of the lines — and reports how many older ones it left behind.
After parsing the file, the app asks for a destination: the real Watch Later playlist when the web
session is connected, or a custom playlist from the Google account. Custom playlist writes cost
50 quota units per video and stop visibly if the quota or a request fails.

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
the Cloud project behind the key or OAuth client, so anything else using that project spends from the same pot
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

Choose **Settings → Downloads → Download Using**:

- **On This Device** (the default on a new installation): resolves and downloads directly from
  YouTube, then joins the video and audio on the device. No resolver URL, token, Python install,
  FFmpeg install, or third-party download service is needed.
- **My Server**: keeps the existing resolver workflow. Existing installations with a saved
  endpoint keep this choice when upgrading; selecting local mode preserves the saved server.
  Accepting a server setup link explicitly switches back to My Server.

Media transfers use a **background `URLSession`**, with up to two queued videos active at a time.
Native media is fetched in bounded 4 MiB byte ranges (unbounded requests can be refused by
YouTube). Each split download transfers video then audio; its current stage and completed byte
offset are saved in the manifest, so
background transfers can be adopted after relaunch. Native Resume starts at the last completed
block; server downloads use available URLSession resume data. Retry resolves fresh links and
restarts expired downloads. A failed attempt shows
its reason and offers Retry. HTTP error pages and files without both audio and video are rejected.

**Keep the app open during extraction and final assembly.** These stages execute in the app,
with a short iOS background allowance. If that allowance expires, the job pauses. Completed audio
and video tracks can be assembled on Resume, even offline. Force-quitting the app may cancel
system transfers; background execution is ultimately controlled by iOS.

Settings holds a maximum quality (360p, 720p, 1080p), a Wi-Fi-only switch, and a storage limit.
The local engine selects compatible H.264/AAC MP4 tracks at or below that height, preserving audio;
it does not silently fetch a higher resolution or a silent video. Separate tracks are joined
without re-encoding using **AVFoundation**. Assembly temporarily needs room for both inputs and
output, which counts against the storage limit. Media requests disallow expensive/cellular
connections when Wi-Fi Only is enabled; local extraction checks the network before starting.
Downloads are excluded from iCloud backups.

### The on-device engine

[YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) **0.4.9** is pinned in the Xcode project
and `Package.resolved`. The app always requests `methods: [.local]`: the library's optional remote
fallback is never enabled. Its Swift extractor and JavaScriptCore solver run inside the app on
iOS and macOS. The solver includes code from yt-dlp/ejs, but the app does not embed the Python
`yt-dlp` executable or invoke a shell.

This is lighter than embedding CPython and a separate JavaScript runtime on iOS. **yt-dlp remains
a good fit for the optional server**, where updating the extractor independently is easy. The
local extractor ships with the app: YouTube changes may require an app update, and live streams,
private, age-restricted, or otherwise gated videos may not be available. A local failure never
silently sends the request to the configured server; switch modes explicitly if needed.

Xcode resolves the Swift package during the build. At runtime, there are no engines or tools to
install. Dependency notices ship in Settings → About → Open Source Licenses.

The offline Swift tests cover format selection, settings migration, old manifests, real local
HTTP transfers, audio/video assembly, interrupted assembly recovery, late cancellation callbacks,
and HTTP errors. Fixtures are synthetic one-second H.264/AAC files. For an optional real network
check against Blender's public Big Buck Bunny video, run the usual macOS test command with
`TEST_RUNNER_BETTERYOUTUBE_LIVE_DOWNLOAD=1` in the environment and
`-only-testing:BetterYouTubeTests/LiveLocalDownloadTests`. For this live background-session test,
keep the app's normal macOS sandbox entitlements: **omit** the `CODE_SIGN_ENTITLEMENTS=""`
override used by the offline loopback tests. An unsandboxed test host can fail with
“Cannot create file” in the system download service. Set `TEST_RUNNER_BETTERYOUTUBE_LIVE_VIDEO`
to another public video ID if desired. The same opt-in test runs in the iOS Simulator.

Validation: the offline suite passes on macOS and the iOS Simulator. The live test also downloads
and assembles the complete demonstration video on both, using the production background-session
configuration. Real-device iPhone background scheduling still needs device validation.

### Optional resolver

Select **My Server** and configure a resolver you run. The server receives the URL and requested
quality and returns a media file URL. Server credentials stay in the keychain and are used only
for the server request, never for local extraction or YouTube's media URLs.

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

The server API still expects a single file. A server reply with ambiguous **separate streams**
is refused rather than guessing their codecs or which one contains audio. Native extraction
provides the track metadata needed for local assembly; arbitrary server replies do not. A media
link that isn't absolute `http(s)` is dropped at the resolver
rather than handed to the downloader, which is a worse place to find out about it.

A token can be set for a service that isn't open to the internet. One typed with its own scheme
(`Api-Key abc123`) is sent as it stands; a bare one is sent as `Bearer`.

### One is included

`resolver/` is a working one: about 400 lines of Python standard library around **yt-dlp**, with a
test suite that runs offline. That split is deliberate — yt-dlp is the only part that needs keeping
current, and it is maintained by people who do it full time, so the container refreshes it on every
start.

**Run it on your own network**, which is not a preference but the thing that decides whether this
works at all. YouTube distrusts datacenter IP ranges, so a resolver at a hosting provider is
usually answered with *"Sign in to confirm you're not a bot"* rather than a video, and no setting
talks it round. A home connection is an ordinary residential address and is simply not treated that
way.

```sh
cd resolver && docker compose up -d
```

Then open `http://<your-machine's-LAN-address>:8080` **on the phone** and tap *Set up Better
YouTube*. Nothing is typed and no token is copied: the resolver serves a page carrying its own
address and access token as a `betteryoutube://` link, and the app asks you to confirm before
saving it. Tailscale or a Cloudflare Tunnel puts that within reach from outside the house while
keeping the requests on your own connection.

**There is no address to configure.** The resolver works out how it was reached from each request,
so it is right whether that is a LAN address, a tunnel or a hosting domain — which removes the
setting that otherwise goes wrong most often, and with it every link that would have pointed at its
own localhost.

`render.yaml`, `fly.toml` and `railway.json` are there for hosting it instead, with the free plans
pinned where that is a choice — but expect the bot check, and read
[`resolver/README.md`](resolver/README.md) on what getting round it costs before you rely on it.

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
not on anyone else. The local mode is available without configuration; server mode requires a
valid endpoint before it can start downloading.

## Running on a Mac

The Mac build is a **native AppKit-backed SwiftUI app**, not Catalyst and not "Designed for iPad":
same target, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`, `SDKROOT = auto`. Pick
*My Mac* as the run destination and build.

Requirements: **macOS 26+**, Xcode 26+.

### What is different, and why

| | iPhone / iPad | Mac |
| --- | --- | --- |
| Sections | Tab bar that minimizes on scroll | Source-list sidebar, ⌘1/⌘2/⌘3 |
| Home's feed switcher | Segmented control at the top of the feed | In the window's toolbar, where a mode switcher belongs |
| Player full screen | Turn the phone on its side | ⇧⌘F fills the window; the green button takes the window full screen |
| Mini / expanded player | Tap the bar, flick it down | ⇧⌘P, or click the bar |
| Transport | The docked bar, the lock screen | The bar, the **Playback** menu, ⌘P / ⌥⌘← / ⌥⌘→ / ⇧⌘N |
| Settings | A tab; panes that push | Its own window, the same panes as a source list, ⌘, |
| Refresh | Pull down | A Refresh button in the toolbar, ⌘R |
| Search field | Pinned to the bottom, in thumb reach | Pinned to the top, where a Mac keeps one |
| YouTube's own pages | `m.youtube.com` | `www.youtube.com` — a window holds the desktop site |
| Periodic new-upload check | `BGAppRefreshTask`, on iOS's schedule | The app's own two-hour timer; an open Mac app is running |
| Downloaded files | The Files app, under "Better YouTube" | Downloads → **Show in Finder** |
| Tokens | iOS keychain | The data-protection keychain, which is why the Mac build is sandboxed |

Everything else — sign-in, the API client, the quota tally, the download queue, the on-device
library, the notification inbox — is one implementation. Settings is divided into the same seven
panes on both, by `SettingsPane`; only the shell around them differs, a pushing list against a
source list.

### How the code is split

There is no `#if os(macOS)` scattered through the views. `Platform.swift` names everything the two
platforms spell differently — `PlatformImage`, the key window, the surface colours, the modifiers
only one of them has — and the rest of the app uses those names. Where a difference is *real*
rather than cosmetic (a phone can be turned on its side; a Mac app is never suspended), the `#if`
stays in the file that cares and is commented there: `PlayerManager`, `BackgroundRefresh`,
`LocalPlayerSurface`, `RootTabView`.

The Mac build is **sandboxed** (`BetterYouTube-macOS.entitlements`): network client, read-only
access to the one CSV you pick when importing Watch Later, and nothing else. That is also what
gives the app a keychain access group of its own, so the OAuth token lands in the app's keychain
rather than your login keychain — without it macOS would ask for your password the first time the
app read its own credentials back.

## Getting started

1. Open `BetterYouTube/BetterYouTube.xcodeproj` in Xcode 26+ and run on an iOS 26+ simulator or
   device, or pick *My Mac* for the macOS 26+ build.
2. **Google sign-in** (recommended): in the Google Cloud Console, [enable the YouTube Data API v3](https://console.cloud.google.com/apis/library/youtube.googleapis.com)
   and [create an OAuth 2.0 client ID](https://console.cloud.google.com/auth/clients) of type **iOS** with the app's bundle identifier
   (`com.atomtoto.BetterYouTube`, or your own). That client type covers macOS too — the same
   client ID works for both builds, and both use the reversed client ID as their callback scheme.
   Paste the client ID on the welcome screen or in Settings, then tap *Sign in with Google*.
   - **Add yourself as a test user**, or sign-in fails with `Error 403: access_denied`. In
     [Google Auth Platform → Audience](https://console.cloud.google.com/auth/audience), with publishing status **Testing**, only the accounts listed
     under *Test users* may grant consent — add the Google account you sign in with. Alternatively
     switch the app to **In production** (with the sensitive `youtube.force-ssl` scope you'll then see
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
     the system only offers them in Safari itself, and the callback scheme is the reversed client ID —
     entered at runtime, so it can't be declared in `Info.plist` and the flow can't move to
     Safari. Sign in to Google in Safari with your passkey instead; the session is not ephemeral,
     so the sheet borrows those cookies and asks for nothing.
   - Scope requested: `https://www.googleapis.com/auth/youtube.force-ssl` — read/write for account
     actions such as likes, comments and custom playlists. A token granted for a narrower scope
     can't be widened in place, so the app drops it and asks you to sign in once more when the
     scope changes. Tokens are stored in the keychain — the iOS one, or the data-protection
     keychain on macOS. So is the download resolver's bearer token, for the same reason. The API
     key lives in `UserDefaults`: it is a quota identifier rather than a credential, it is visible
     in every request the app makes, and Google's own advice is to restrict it rather than hide it.
3. **API key** (optional alternative): [create an API key credential](https://console.cloud.google.com/apis/credentials) in the same Cloud project if
   you prefer public browsing without Google sign-in. Paste it on the welcome screen or in Settings.
   Account features still require OAuth. You can also keep both: the key handles public requests.
4. **YouTube Home** (optional): after setting up OAuth or an API key, the welcome screen offers a
   separate sign-in to youtube.com. Connect it for your real personalized Home feed and YouTube
   Watch Later. You can skip it and connect later in Settings → YouTube Home.

## Project structure

```
render.yaml                      One-click deploy of the resolver below
resolver/                        A yt-dlp resolver: server.py, Dockerfile, compose, tests
BetterYouTube/
  BetterYouTube.xcodeproj/       Xcode project (one app target, iOS 26+ and macOS 26+)
  BetterYouTube/
    BetterYouTubeApp.swift       App entry point, both app delegates, the Mac's menu bar
    Platform.swift               The iOS/macOS seam: typealiases, colours, window, modifiers
    Info.plist                   iOS
    Info-macOS.plist             macOS
    BetterYouTube-macOS.entitlements   The Mac build's sandbox
    Theme.swift                  Design tokens + shared artwork/avatar/section components
    Models.swift                 Domain models and YouTube API decoding
    YouTubeAPIService.swift      API client (actor) with OAuth + API key support
    GoogleAuthService.swift      OAuth 2.0 PKCE sign-in, keychain token storage
    Persistence.swift            On-device library and recent searches
    QuotaTracker.swift           The day's quota spending, counted call by call
    DownloadStore.swift          The Downloads folder, its manifest and what is in it
    DownloadService.swift        Download modes, settings and the optional server API
    LocalDownloadResolver.swift  On-device extraction, format selection and AVFoundation assembly
    DownloadManager.swift        The background download queue
    LocalPlayback.swift          AVPlayer half of the player, for downloaded files
    DownloadConfigLink.swift     betteryoutube:// setup links, and their QR codes
    YouTubeWebSession.swift      Optional youtube.com web session + home-feed reader
    Utilities.swift              Duration, count and relative-date formatters, Takeout CSV reader
    Keychain.swift               The two credentials this app keeps, and where they are kept
    ViewModels/                  One @MainActor view model per screen
    Views/                       SwiftUI screens
    Views/Settings/              One file per settings section, the panes, and each shell
    Views/Components/            Reusable cards and rows
  BetterYouTubeTests/            Unit tests for the pure parts
```

## Continuous integration

`.github/workflows/build.yml` builds the app with `xcodebuild` on a GitHub-hosted macOS runner for
every push and pull request — **once for the iOS simulator and once for macOS** — so compile errors
surface without a local Mac, and so the platform nobody is currently working on can't quietly stop
compiling.

A third job runs the unit tests (`BetterYouTubeTests`) on macOS. They cover the pure parts, which
are the ones worth pinning down because nothing on screen tells you when they are wrong: the ISO
8601 duration formatter, the Google Takeout CSV reader, the abbreviated counts, and what a
`betteryoutube://` setup link accepts and refuses. macOS rather than the simulator because it needs
no device booted; the code under test has no platform in it either way.

## Notes

- Unofficial client; not affiliated with YouTube or Google.
- Streaming playback uses the YouTube IFrame embed rather than extracting stream URLs. The app
  resolves media URLs for downloads only, on-device by default or through your optional server.
  See [Downloads](#downloads).
