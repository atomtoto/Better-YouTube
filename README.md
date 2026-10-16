# Better-YouTube

An unofficial YouTube client for **iOS, macOS and watchOS**, built with SwiftUI and designed to feel like a
native Apple app (Apple Music-style shelves, artwork cards, inset-grouped library, context menus,
share sheets).

One target builds iOS and macOS. The phone gets a tab bar, a docked player over it and a video that goes
full screen when you turn the phone on its side; the Mac gets a sidebar, a menu bar with keyboard
shortcuts and a window. Everything between those two — the API client, the player, the download
queue, the iCloud-backed library — is the same code. A separate Watch app has a compact library,
search, and offline audio. See [Running on Apple Watch](#running-on-apple-watch) and
[Running on a Mac](#running-on-a-mac).

## Features

- **Home** — *For You* (YouTube's charts for the categories you watch, woven with new uploads
  from the channels you watch most), *Subscriptions*, and — with a youtube.com session — your real
  YouTube home feed; see [Recommendations](#recommendations)
- **Search** — the system's search field, in a button of its own at the end of the tab bar that
  turns into the field along the bottom. Searches run when you submit (a search costs 100 quota
  units), with filters for sort order, length and upload date, *More Results* on demand and recent
  searches. As you type, the field suggests your matching recent searches and YouTube's own
  completions — free of quota, and switched off in Settings → Library. Pasting a YouTube link
  opens it instead of searching for it — see [Opening YouTube links](#opening-youtube-links)
- **Playback** — the official YouTube embedded player (WKWebView), so playback stays within
  YouTube's Terms of Service, under the app's own native controls: play and pause, 10-second
  skips (also a double tap on either half of the video), a scrubber split into the video's
  chapters, captions, Picture in Picture, full screen, and a settings menu with YouTube's own
  choices — quality, captions and their auto-translation, audio track and speed. Holding the right
  half of the video plays it at 2× while held (Settings → Playback). A downloaded video gets the
  same controls. YouTube's own layer only shows through for an ad or its end-screen suggestions.
  Turning the phone on its side, or the full-screen button, plays the video full screen in the
  same player — or in iOS's own, if Settings → Playback → Full-Screen Player says so — and turning
  it back puts the player where it was. On a Mac, ⇧⌘F fills the window instead. On an iPad held
  landscape the player stands in two columns: the video with its details, and beside it up next
  and the comments. Autoplay of the next video can be turned off in Settings → Playback, and a
  sleep timer in the player's menu stops playback after a while or at the end of the video
- **Resume playback** — reopening a video on iPhone, iPad or Mac continues from its last saved
  position, including downloaded videos. Positions survive app launches and sync through iCloud;
  videos that reached the end start again from the beginning. Artwork shows how much of a video
  was watched, and Library lists what was left part-way through under *Continue Watching*
- **Video detail** — stats, a description whose timestamps seek the video and whose YouTube links
  open in the app, comments (Top or Newest, page after page, with tappable timestamps too), a
  share sheet — including *Share at 1:23* — and a thumbs-up that is the real like on your YouTube
  account (the heart beside it is the app's own favorites)
- **Channels** — profile header, every upload page by page, the channel's public playlists, and
  Subscribe/Unsubscribe on the account
- **Library** —
  - *Signed in with Google*: your subscriptions, playlists and liked videos
  - *Your library*: favorites, the app's Watch Later and watch history, with iCloud sync
  - Every long list — subscriptions, playlists, history, Watch Later — can be filtered in place
  - *Play* and *Shuffle* on a playlist take the whole of it, not just the part scrolled through
- **Shortcuts, Siri and Spotlight** — *Open YouTube Link*, *Search YouTube*, *Resume Watching*
  and *Play Library List* (Watch Later, Favorites or History, shuffled or not), with Siri phrases
  in English and French that need no setup. A shortcut built on *Open YouTube Link* with *Show in
  Share Sheet* turned on is how Safari or the YouTube app send a link here
- **Handoff** — pause on the iPhone and the Mac offers to carry on from the same second, and the
  other way round; a device without the app opens the video's page at that moment instead
- **Demo mode** — try everything without an account or a key: real videos from a built-in
  catalogue, a read-only demo account, and a library of its own that is deleted when you leave; see
  [Demo mode](#demo-mode)
- **Languages** — English and French, on every platform; see [Localization](#localization)
- **iCloud Sync** — favorites, the app's Watch Later, watch history, playback positions, and mini player style and
  size shared between iPhone, iPad and Mac using the same Apple Account; see [iCloud Sync](#icloud-sync)
- **Downloads** — videos kept in a `Downloads` folder on the device and played from the file
  wherever they turn up in the app, with no network at all. Downloads run directly on the device;
  a self-hosted resolver remains optional — see [Downloads](#downloads)
- **Background playback** — the sound carries on when the app is left or the iPhone locks, with
  title, artwork, scrubber and transport on the lock screen and in Control Centre (on a Mac: the
  media widget in Control Centre and the keyboard's play/pause key). WebKit can't play once the
  app is away, so a streamed video's sound moves to the native player — YouTube's sound-only
  stream, fetched in bounded ranges, which YouTube serves at full speed — and the queue goes on
  the same way; back in the app, the embed takes the picture back at the same moment. Turned off
  in Settings → Playback, the video pauses instead. Picture in Picture, off unless turned on
  there, moves a playing video to its window when you go to the Home Screen
- **Settings** — Google sign-in, API key, library counts, what is left of the day's API quota,
  whether the app opens on Home or Library, and a reset that puts the device back to a fresh install
- **Apple Watch** — synced YouTube Home and library, direct search with the watch's network,
  audio downloads saved on the watch, and offline playback with background audio
- **Apple CarPlay** — Favorites, Watch Later, History and Downloads, native Now Playing controls,
  an Up Next list, saved positions, and parked video in compatible cars with iOS 27

## Demo mode

*Try Without Signing In* on the welcome screen — or a `betteryoutube://demo` link, which is what a
tester or App Review can be handed — opens the app on a catalogue of real, public videos: Blender's
open movies, NASA, CNES, NoCopyrightSounds, MIT OpenCourseWare and the first video ever uploaded.
They play for real, through the same embed as always; it needs no key.

Every screen works, because the app itself is unchanged: while a demo runs, its requests to the
Data API are answered on the device by `DemoServer`, from `DemoCatalog.json`, in the API's own
JSON. Home's two feeds, search with its filters and suggestions, channels and their playlists,
playlists, Library and the notifications inbox all fill from it, and nothing reaches Google — not a
request, not a unit of quota.

The demo has an account to show — subscriptions, two playlists, liked videos — but it is read-only:
liking, subscribing, commenting or editing a playlist says it needs a Google sign-in, and comments
aren't part of the catalogue. Favorites, Watch Later, history, playback positions and downloads all
work, in a library of the demo's own: the real one is put aside untouched, iCloud sync and the
watch are paused, and quitting the demo — from Settings, or the *Demo* menu on Home and Library —
deletes everything it kept, the videos downloaded meanwhile included.

`scripts/build-demo-catalog.py` rebuilds the catalogue from the videos' public pages; the numbers
in it are a snapshot of the day it ran.

## Running with Apple CarPlay

CarPlay presents four library tabs. Selecting an item starts native playback and queues the
following items in that list. Downloads play from the iPhone's files without a network connection;
other items resolve a native stream and need internet access. If a stream cannot be resolved or
played, CarPlay shows an error. You can retry from the playback controls or
select another item. The iPhone and CarPlay share one player, queue and playback position.

On iOS 27, cars advertising video support receive playable items with a video presentation
preference through `CPPlaybackConfiguration`. AVPlayer supports external playback via AirPlay;
CarPlay controls the video presentation and switches to audio when vehicle policy disallows video.
The app does not infer parking from keyboard/list restrictions or provide a manual override.
Other cars and older iOS versions use audio. Online video uses a compatible H.264/AAC stream;
if none is available, the item falls back to AAC audio. See Apple's
[CarPlay video overview](https://developer.apple.com/videos/play/wwdc2026/212/).

Connecting CarPlay hands any current online playback to the native player, including when it
is paused. Disconnecting keeps the current playback and queue alive. A new selection on the phone
after disconnecting returns to normal video playback. Account sign-in and library setup remain in
the iPhone app. Watch Later refreshes on connection and when the CarPlay scene becomes active;
favorites, history and downloads update as their stores change.

The iOS target declares `CarPlaySceneDelegate` in its scene manifest and includes
both `com.apple.developer.carplay-audio` and `com.apple.developer.carplay-video`. For a signed
device build, request Apple's
[CarPlay entitlements](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
for your app ID and regenerate its provisioning profile after approval. Adding the entitlement to
the project alone does not grant Apple's approval. macOS and watchOS do not request it.

For interface validation, use CarPlay Simulator in Device Hub. For video testing, Apple's
CarPlay Simulator from **Additional Tools for Xcode** supports video-capable vehicle configurations.
Verify a launch with no phone window, all four library tabs, an empty library, Now Playing and
Up Next, play/pause and seeking, queue advancement, unavailable streams, and offline downloaded
playback. Test both video-capable and audio-only cars. In a video-capable configuration, select
downloaded and online video while parked, then disallow video and confirm only audio remains;
reallow video and verify the system resumes its presentation. Connect during both playing and
paused phone playback, then disconnect and confirm playback continues. Repeat on a provisioned
iPhone in a CarPlay vehicle, including screen lock, audio interruptions and reconnection.
Unit tests and unsigned builds do not validate device provisioning or the vehicle interface.

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

The app records its own watch history and can sync it through iCloud; this does not read or write
your YouTube account's history. With **Settings → YouTube Home → youtube.com** connected,
**Watch Later uses the account's real `WL` playlist**, including reads, additions and removals.
Requests run inside the signed-in website's WebKit context; authentication cookie values are
not returned to Swift, persisted separately, logged or sent to another service. This uses
YouTube's internal website endpoints, not a supported public API, and may break when YouTube
changes them. Pagination and server confirmation are checked; failures never silently save to
a different list. Live account behavior still needs verification on a signed-in device.

Without a web session, the app's Watch Later is stored locally and can sync through iCloud.
The app no longer discovers, creates or
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

## iCloud Sync

**Settings → Library → iCloud Sync** enables the same private library on iPhone, iPad and Mac
signed into the same Apple Account. It is enabled by default; the status row reports when iCloud
is unavailable, and **Sync Now** requests another synchronization. Local library changes still
work offline and wait for a connection. Synchronization is asynchronous: background delivery
depends on the system, and opening the app or using Sync Now lets it catch up.

The synchronized data is deliberately limited to **favorites, the app's Watch Later, watch
history, playback positions, and mini player style and floating size**. The most recent playback
checkpoint wins across devices, including backward seeks. Finishing a video clears its resume
point everywhere after synchronization. The youtube.com Watch Later playlist is
managed by YouTube and remains separate from the app's fallback list. Apple Watch receives the
updated library through Watch Connectivity from its paired iPhone; it does not connect to
CloudKit directly.

Downloaded media and manifests, API keys, Google and youtube.com sessions, download service
credentials and settings, recent searches, quota counters, and notification settings and inboxes
remain on each device. Turning off sync keeps the local library and the existing cloud copy.
Clearing watch history while sync is enabled propagates that deletion. **Reset App** first turns
off sync on that device and clears its local data; other devices and the cloud library remain
intact. Enabling sync again can restore the saved cloud library.

### Signing and container setup

The project builds with **any Apple account, a free one included** ("Personal Team"), with no
Apple Developer Program membership: copy `BetterYouTube/Config/Local.xcconfig.example` to
`Local.xcconfig` (git ignores it), put your Team ID in it and press Run. What the account can sign
decides what the build gets:

| Team | iCloud sync and push | CarPlay | iOS entitlements |
| --- | --- | --- | --- |
| Free (Personal Team) | no | no | `BetterYouTube-iOS-PersonalTeam.entitlements` |
| Paid | yes | no | `BetterYouTube-iOS-iCloud.entitlements` |
| Paid, with the CarPlay entitlements granted | yes | yes | `BetterYouTube-iOS.entitlements` |

Before every build, both schemes run `scripts/detect-signing.sh`, which asks Xcode whether the team
is a free one and writes the answer to `Config/Detected.xcconfig`; `Config/Signing.xcconfig` picks
the entitlements from it. Moving to a paid team turns iCloud on with no other change. CarPlay
can't be detected — Apple grants its audio and video entitlements on request — so it is turned on
with `BY_CARPLAY = YES` in `Local.xcconfig`; the detection can be overridden there too with
`BY_ICLOUD = YES` or `NO`. A free account can't use a bundle identifier another account holds:
set `BY_BUNDLE_ID` to one of your own, and register it with your Google OAuth client. The watch
app, the tests and the iCloud container (`iCloud.<bundle identifier>`) follow it. Builds signed by
a free team expire after seven days.

The app finds out at launch what its build was signed with — the Mac from its own entitlements,
an iPhone from its embedded provisioning profile — and in a build without iCloud, Settings says so
and keeps sync off, rather than offering a switch that does nothing.

With a paid team:

1. Xcode registers the container `iCloud.<bundle identifier>` with your app ID on the first signed
   build. See Apple's
   [CloudKit setup guide](https://developer.apple.com/documentation/cloudkit/enabling-cloudkit-in-your-app).
2. Push notifications and **Background Modes → Remote notifications** are already set. The
   entitlement files use the development APNs environment for local development; verify the final
   signed archive uses the environment required by its distribution profile. Preserve the Mac's
   App Sandbox entitlements, which every variant keeps.
3. Run a signed build with an Apple Account signed into iCloud. Unsigned builds and offline test
   hosts do not validate live iCloud synchronization; tests and previews skip live engine initialization.

The service uses `CKSyncEngine` with a custom zone named **`BetterYouTubeLibrary`** in the user's
private CloudKit database. The record type is **`LibraryEntry`** with **`schemaVersion`** (Int64,
currently `1`) and **`payload`** (Data containing a JSON-encoded entry). Deterministic record IDs
identify each favorite, Watch Later item, history item, or player preference. Removal entries
retain a tombstone so a device reconnecting after an offline deletion does not resurrect that
item. The sync engine's state and pending changes are persisted locally.

Development saves create the record schema. After testing those saves, use
[CloudKit Console](https://icloud.developer.apple.com/) to inspect the development schema and
**deploy it to production before distributing a TestFlight or App Store build**. Schema deployment
does not copy development records into production. Follow Apple's
[schema deployment guide](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).

### Device validation

Live synchronization still requires validation on **two signed devices** using the same Apple
Account, container, and CloudKit environment. A local build and unit tests cannot establish that
Apple's provisioning, account access, push delivery, or production schema is working.

Verify favorites and fallback Watch Later additions and removals, history changes and clearing,
playback positions, and mini player style and size in both directions. For resume positions,
pause on one device and open the same video on the other; also check backward seeks, completion,
and switching between streaming and a downloaded copy. Make changes while one device is offline,
including a removal, then reconnect and confirm they converge without reviving removed items.
Check restart, background/foreground catch-up, Sync Now, iCloud sign-out or account change, and
disabling sync. Reset one device and verify the other device and cloud copy retain the library;
enable sync again and confirm it restores. Finally confirm credentials and downloaded files
have stayed local, and that the paired Watch receives library and history changes from its iPhone.

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
app polls instead — the channels you turned notifications on for in *Selected Channels* mode (an
API key is enough for those), or your subscriptions in *All Subscriptions* mode, at most once every
30 minutes unless you pull to refresh. A channel read for the first time only announces what it
uploaded in the last day, so turning its bell on doesn't replay its back catalogue. What the web session can reach is the account's own notification inbox, and
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

## Opening YouTube links

Search opens a pasted YouTube link rather than searching for it: one quota unit at most, against
the hundred a search would cost, and exactly the thing that was shared. Every shape YouTube hands
out is recognised, on any of its hosts and with or without `https://`:

| Link | Opens |
| --- | --- |
| `youtube.com/watch?v=…`, `youtu.be/…`, `/shorts/…`, `/live/…`, `/embed/…` | The video, at the shared `t=` or `start=` time |
| `youtube.com/playlist?list=…` | The playlist |
| `youtube.com/channel/UC…`, `youtube.com/@handle`, or just `@handle` | The channel |

The same links reach the app from outside through its own scheme, which is what Shortcuts or
another app can use: swap `https` for `betteryoutube` in any YouTube link
(`betteryoutube://youtu.be/dQw4w9WgXcQ?t=42`), or use `betteryoutube://watch?v=…&t=…` or
`betteryoutube://open?url=<a percent-encoded YouTube link>`. `betteryoutube://search?q=…` opens
Search on those words. The *Open YouTube Link* action in Shortcuts does the same without a URL to
build.

A video opened by link plays even before an API key or a sign-in is set up: the embed needs only
the ID, and the title and channel come from YouTube's keyless oEmbed endpoint until the Data API
can be asked. Inside the app, YouTube links in descriptions and comments open the same way, and
timestamps in them seek the video on screen.

## Localization

The app ships in **English and French**, on iPhone, iPad, Mac, CarPlay and Apple Watch. Strings
live in String Catalogs — `BetterYouTube/Localizable.xcstrings`, `BetterYouTube/InfoPlist.xcstrings`,
`BetterYouTube/AppShortcuts.xcstrings` (the Siri phrases) and `BetterYouTubeWatch/Localizable.xcstrings`
— with plural variants for counts in both languages,
and the French uses the informal *tu*. Numbers, dates, durations and percentages go through
Foundation's formatters, so they follow the reader's region.

To add a language, add it in the project's Info → Localizations in Xcode and fill in the
catalogs, or export with `xcodebuild -exportLocalizations -project BetterYouTube.xcodeproj
-localizationPath out -exportLanguage <code>` and import the translated `.xcloc` back with
`-importLocalizations`. Write new interface text as a literal in `Text`, `Label`, `Button` and
friends, or as `String(localized:)` when it has to travel as a `String`, so it is extracted.

The test action is pinned to English, so tests that check a message read the same on any machine.

`scripts/check-localizations.py` fails when any string the apps show has no French translation —
one added in code and never put in a catalog as well as one left untranslated. It leaves the
working copy as it found it, so it is safe to run whenever you like.

## Running on Apple Watch

The `BetterYouTubeWatch` target builds for **watchOS 26+** and is embedded in the iOS app. Build
the `BetterYouTubeWatch` scheme for a Watch simulator, or install the iOS app on a paired iPhone
and its Watch app on the watch. Open the iPhone app once after installation to synchronize data.

- **Home** shows the latest personalized YouTube feed already loaded on the iPhone. Connect
  *Settings → YouTube Home* on the iPhone, then open its YouTube feed to update what the watch
  caches. The watch keeps that feed when the iPhone is away; it cannot read the signed-in website
  on its own.
- **Search** uses the YouTube Data API directly over the watch's network. Set an API key on the
  iPhone; Watch Connectivity sends that key to the watch, which stores it in its own keychain.
  An OAuth-only setup has no key for independent watch search. Search requests consume the same
  Cloud project's quota as the iPhone, but the iPhone's local quota counter does not see them.
- **Library** caches the full favorites, Watch Later, history and downloaded-video lists from
  the iPhone. When the Google OAuth account is connected, it also transfers subscriptions,
  playlists and liked videos. Public
  channel uploads and playlist contents load through the watch's Data API connection; private
  playlists can ask the reachable iPhone and retain the results for later viewing.
- **Offline audio** has two paths. Choose a video on the watch and tap *Download to Watch* while
  the iPhone is reachable: the iPhone resolves a compatible M4A audio track, then the watch
  fetches it in bounded ranges over its own network. Keep the Watch app open until that download
  finishes; an interrupted download resumes from its last completed range when retried. For a
  video already downloaded on the iPhone, tap *Transfer from iPhone*; Watch Connectivity moves
  the existing MP4 in the background. That file can be much larger than the audio-only option.
  Playback uses the file on the watch and continues when the wrist is lowered, with a Bluetooth
  audio route selected by watchOS.

The watch does not stream a new YouTube video or audio track by itself. watchOS has no WebKit
player for the app's embedded playback, and the Data API supplies metadata rather than a playable
media URL. Preparing a new download requires the iPhone to be reachable; once the file is saved,
listening needs neither iPhone nor network. File transfer timing and background audio routing
should be checked on a paired physical watch.

## Running on a Mac

The Mac build is a **native AppKit-backed SwiftUI app**, not Catalyst and not "Designed for iPad":
same target, `SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx"`, `SDKROOT = auto`. Pick
*My Mac* as the run destination and build.

Requirements: **macOS 26+**, Xcode 27+ for the full project.

### What is different, and why

| | iPhone / iPad | Mac |
| --- | --- | --- |
| Sections | Tab bar that minimizes on scroll | Source-list sidebar, ⌘1/⌘2/⌘3 |
| Home's feed switcher | Segmented control at the top of the feed | In the window's toolbar, where a mode switcher belongs |
| Player full screen | Turn the phone on its side | ⇧⌘F fills the window; the green button takes the window full screen |
| Mini / expanded player | Tap the bar, flick it down | ⇧⌘P, or click the bar |
| Transport | The docked bar, the lock screen — and on an iPad, the same **Playback** menu and shortcuts | The bar, the **Playback** menu, ⌘P / ⌥⌘← / ⌥⌘→ / ⇧⌘N |
| Settings | A tab; panes that push | Its own window, the same panes as a source list, ⌘, |
| Refresh | Pull down | A Refresh button in the toolbar, ⌘R |
| Search field | A button of its own at the end of the tab bar, which turns into the field along the bottom | In the window's toolbar, where a Mac keeps one |
| YouTube's own pages | `m.youtube.com` | `www.youtube.com` — a window holds the desktop site |
| Periodic new-upload check | `BGAppRefreshTask`, on iOS's schedule | The app's own two-hour timer; an open Mac app is running |
| Downloaded files | The Files app, under "Better YouTube" | Downloads → **Show in Finder** |
| Tokens | iOS keychain | The data-protection keychain, which is why the Mac build is sandboxed |

Everything else — sign-in, the API client, the quota tally, the download queue, the synced
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

The Mac build is **sandboxed** (`BetterYouTube-macOS.entitlements`): network client and read-only
access to the one CSV you pick when importing Watch Later, plus CloudKit and push entitlements
for library synchronization. The sandbox is also what
gives the app a keychain access group of its own, so the OAuth token lands in the app's keychain
rather than your login keychain — without it macOS would ask for your password the first time the
app read its own credentials back.

## Getting started

1. Open `BetterYouTube/BetterYouTube.xcodeproj` in Xcode 27+ and run on an iOS 26+ simulator or
   device, or pick *My Mac* for the macOS 26+ build. To run on a device, put your Team ID in
   `BetterYouTube/Config/Local.xcconfig` first — a free Apple account works; see
   [Signing and container setup](#signing-and-container-setup).
2. **Google sign-in** (recommended): in the Google Cloud Console, [enable the YouTube Data API v3](https://console.cloud.google.com/apis/library/youtube.googleapis.com)
   and [create an OAuth 2.0 client ID](https://console.cloud.google.com/auth/clients) of type **iOS** with the app's bundle identifier
   (`com.atomtoto.BetterYouTube`, or your own). That client type covers macOS too — the same
   client ID works for both builds, and both use the reversed client ID as their callback scheme.
   Paste the client ID on the welcome screen or in Settings, then tap *Sign in with Google*.
   - **Publish the app** (recommended). While the publishing status is **Testing**, Google
     expires refresh tokens after **7 days**, so you'd be asked to sign in again about once a
     week; in production the sign-in lasts until you revoke it, change your password or leave it
     unused for about six months. Google won't enable *Publish app* until the
     [Branding](https://console.cloud.google.com/auth/branding) page carries a home page, a privacy policy and terms of service, all on an
     authorized domain. The project's own pages, served by GitHub Pages from `docs/`, work for
     anyone's Cloud project:

     | Branding field | Value |
     | --- | --- |
     | Application home page | `https://atomtoto.github.io/Better-YouTube/` |
     | Application privacy policy link | `https://atomtoto.github.io/Better-YouTube/privacy.html` |
     | Application terms of service link | `https://atomtoto.github.io/Better-YouTube/terms.html` |
     | Authorized domains | `atomtoto.github.io` |

     Leave the logo empty: uploading one makes Google require a review before publishing. Save,
     then click *Publish app* in [Google Auth Platform → Audience](https://console.cloud.google.com/auth/audience). No Google
     verification is needed: the project is yours and you're its only user, well under the
     100-user cap for unverified apps, and proving you own the domain only matters for
     verification. Because `youtube.force-ssl` is a sensitive scope, Google shows a "Google
     hasn't verified this app" screen at sign-in — pass it via *Advanced → Go to …*.
   - **Or add yourself as a test user** and stay in Testing, accepting the weekly sign-in. With
     publishing status **Testing**, only the accounts listed under *Test users* may grant consent,
     so sign-in fails with `Error 403: access_denied` until you add the Google account you sign
     in with.
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
docs/                            Home page, privacy policy and terms (GitHub Pages), for Google's Branding page
render.yaml                      One-click deploy of the resolver below
resolver/                        A yt-dlp resolver: server.py, Dockerfile, compose, tests
BetterYouTube/
  BetterYouTube.xcodeproj/       Xcode project (iOS/macOS app and watchOS app target)
  Config/                        Signing.xcconfig, and the git-ignored Local and Detected ones
  Shared/                       Payloads shared by iPhone and Watch, and thumbnail sizing
  BetterYouTube/
    BetterYouTubeApp.swift       App entry point, both app delegates, the Mac's menu bar
    Platform.swift               The iOS/macOS seam: typealiases, colours, window, modifiers
    Info.plist                   iOS
    Info-macOS.plist             macOS
    BetterYouTube-iOS.entitlements     CloudKit and iOS push notifications
    BetterYouTube-macOS.entitlements   Mac sandbox, CloudKit and push notifications
    Theme.swift                  Design tokens + shared artwork and avatar components
    Models.swift                 Domain models and YouTube API decoding
    YouTubeAPIService.swift      API client (actor) with OAuth + API key support
    GoogleAuthService.swift      OAuth 2.0 PKCE sign-in, keychain token storage
    Persistence.swift            Local library and recent searches
    ICloudSyncService.swift       CloudKit engine, account state and synchronization status
    QuotaTracker.swift           The day's quota spending, counted call by call
    DownloadStore.swift          The Downloads folder, its manifest and what is in it
    DownloadService.swift        Download modes, settings and the optional server API
    LocalDownloadResolver.swift  On-device extraction, format selection and AVFoundation assembly
    WatchPhoneBridge.swift       Watch Connectivity sync and iPhone-assisted audio resolution
    DownloadManager.swift        The background download queue
    LocalPlayback.swift          AVPlayer half of the player, for downloaded files
    DownloadConfigLink.swift     betteryoutube:// setup links, and their QR codes
    YouTubeWebSession.swift      Optional youtube.com web session + home-feed reader
    Utilities.swift              Duration, count and relative-date formatters, Takeout CSV reader
    YouTubeLink.swift            Reads every shape of YouTube link, and the app's own scheme
    AppShortcuts.swift           Shortcuts, Siri and Spotlight actions, and their phrases
    Handoff.swift                The playing video, offered to your other devices
    DemoMode.swift               The demo: starting, ending, and the library it keeps apart
    DemoServer.swift             The Data API as the demo plays it, answered on the device
    DemoCatalog.swift            The demo's videos, channels and playlists, and searching them
    DemoCatalog.json             The catalogue itself, built by scripts/build-demo-catalog.py
    RichText.swift               Tappable timestamps and links in descriptions and comments
    Localizable.xcstrings        The app's strings, in English and French
    InfoPlist.xcstrings          Info.plist strings, in English and French
    AppShortcuts.xcstrings       Siri phrases, in English and French
    Keychain.swift               The two credentials this app keeps, and where they are kept
    ViewModels/                  One @MainActor view model per screen
    Views/                       SwiftUI screens
    Views/Settings/              One file per settings section, the panes, and each shell
    Views/Components/            Reusable cards and rows
  BetterYouTubeWatch/             Watch screens, API browsing, file downloads and audio playback
  BetterYouTubeTests/            Unit tests, and the API client against canned responses
scripts/check-localizations.py   Fails when a string has no French translation
scripts/detect-signing.sh        Detects a free or paid signing team before each build
scripts/build-demo-catalog.py    Rebuilds the demo's catalogue from the videos' public pages
```

## Tests and checks

There is no GitHub Actions workflow: the app is built and tested on a Mac. The hosted macOS runner
compiled with an Xcode whose Swift compiler crashed while generating code for `HomeView.swift`,
which failed every run without a mistake in the code, so the automatic build was removed. It is
still in the git history (`.github/workflows/build.yml`) if you want it back.

The unit tests (`BetterYouTubeTests`) run with ⌘U in Xcode, or from the command line on macOS:

```sh
cd BetterYouTube
xcodebuild test -project BetterYouTube.xcodeproj -scheme BetterYouTube -destination "platform=macOS"
```

They cover the pure parts, which are the ones worth pinning down because nothing on screen tells
you when they are wrong: the ISO 8601 duration formatter, the Google Takeout CSV reader, the
abbreviated counts in English and French, what a `betteryoutube://` setup link accepts and
refuses, which YouTube links open what, which text in a description is a timestamp, and the
new-upload ledger that decides what is worth a notification — alongside downloads, playback
positions, CarPlay and iCloud sync. The API client is tested against canned responses in the Data
API's own JSON: pagination, search decoding, errors and the quota each call is charged, with no
network, key or charge to the real count. macOS rather than the simulator because it needs no
device booted; the code under test has no platform in it either way.

`scripts/check-localizations.py` fails when a string has no French translation — see
[Localization](#localization).

Every target builds in the Swift 6 language mode, so the compiler checks for data races across
threads and actors.

## Notes

- Unofficial client; not affiliated with YouTube or Google.
- Streaming playback uses the YouTube IFrame embed rather than extracting stream URLs. The app
  resolves media URLs for downloads only, on-device by default or through your optional server.
  See [Downloads](#downloads).
