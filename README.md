# Better-YouTube

A functional, unofficial YouTube client for iOS built with SwiftUI.

## Features

- **Trending** feed of popular videos (YouTube Data API v3 `videos.list`)
- **Search** for videos and channels with debounced live results
- **Video playback** via the official YouTube embedded player (WKWebView), so it stays compliant
  with YouTube's Terms of Service and doesn't depend on scraping
- **Video detail**: description, view/like counts, top-level comments, related channel link
- **Channels**: header info and a list of the channel's recent uploads
- **Library**: favorites, watch later, and watch history, persisted locally on-device
- **Settings**: paste in your own YouTube Data API v3 key (stored only in `UserDefaults` on-device)

## Project structure

```
BetterYouTube/
  BetterYouTube.xcodeproj/        Xcode project (iOS App target, iOS 16+)
  BetterYouTube/
    BetterYouTubeApp.swift        App entry point
    Models.swift                  Domain models + YouTube API response decoding
    YouTubeAPIService.swift       URLSession-based YouTube Data API v3 client
    Persistence.swift             Local library storage (favorites/watch later/history)
    Utilities.swift                Formatters (durations, counts, relative dates)
    ViewModels/                   One @MainActor view model per screen
    Views/                        SwiftUI views
    Assets.xcassets, Info.plist
```

## Getting started

1. Open `BetterYouTube/BetterYouTube.xcodeproj` in Xcode 15+.
2. Build & run on an iOS 16+ simulator or device (target: `BetterYouTube`).
3. On first launch, paste a YouTube Data API v3 key when prompted (or later from the
   **Settings** tab):
   - Go to the [Google Cloud Console](https://console.cloud.google.com/).
   - Create a project (or pick an existing one) and enable the **YouTube Data API v3**.
   - Under **Credentials**, create an **API key**.
   - Paste that key into the app. It's stored only on your device.

No backend/server is required — the app talks directly to the public YouTube Data API v3 and
embeds the official YouTube player for playback.

## Notes

- This is an unofficial client and isn't affiliated with YouTube or Google.
- The free tier of the YouTube Data API has a daily quota; heavy use (e.g. many searches) can
  exhaust it, in which case requests will show the API's error message until the quota resets.
