# Better YouTube — download resolver

The app plays video through YouTube's embed, which never exposes a media file, so it cannot
download one by itself. This is the piece that resolves one for it.

It is about 300 lines of Python standard library plus **yt-dlp**, which does the actual
extracting. That split is the point: yt-dlp is maintained against YouTube's changes by people who
do it full time, and it is the only part of this that needs keeping current. The container
refreshes it on every start.

## Run it

```sh
cp .env.example .env     # set PUBLIC_URL, and a token if it will be reachable from outside
docker compose up -d
curl localhost:8080/health
```

Then in the app: **Settings → Downloads**, put the address in, and the same token if you set one.
Or have the app show you a QR code and point a phone at it.

Without Docker: `pip install yt-dlp`, install `ffmpeg`, then `PUBLIC_URL=… python3 server.py`.

## What it costs to run

Two paths, and they are very different for you:

| | When | Bandwidth through this server |
| --- | --- | --- |
| **Direct** | YouTube offers the wanted height already joined (in practice, 360p and sometimes 720p) | **None.** The phone is handed YouTube's own CDN URL and fetches it from Google. |
| **Muxed** | Anything higher — YouTube keeps video and audio apart above 360p, and the app plays one file | All of it. `/media` re-resolves and pipes both streams through ffmpeg into a fragmented MP4 as they arrive. |

Nothing is ever written to disk: the muxed path streams. Set `ALLOW_MUX=0` to refuse the second
path entirely, and this server never carries a byte of video — downloads are then capped at
whatever YouTube happens to offer already joined.

## Settings

| Variable | Meaning |
| --- | --- |
| `PUBLIC_URL` | The address **the phone** reaches this on, not the container's. Muxed links are built from it; unset, they point at localhost and the phone can't reach them. |
| `RESOLVER_TOKEN` | If set, `POST /` needs it and `/media` links are signed with it. Leave empty only on a network you trust. |
| `MAX_HEIGHT` | Ceiling regardless of what the app asks for. `720` keeps the muxed path cheaper. |
| `ALLOW_MUX` | `0` refuses anything needing ffmpeg. |
| `UPDATE_YTDLP` | `0` skips the update on boot. |
| `PORT` | Default 8080. |

## The API

`POST /` — what the app sends, and rather more than it needs:

```json
{"url": "https://www.youtube.com/watch?v=…", "videoId": "…", "videoQuality": "720", "maxHeight": 720}
```

Either `url` or `videoId` will do. The height is read from `maxHeight`, `videoQuality`, `quality`
or `height`, whichever turns up first.

```json
{"status": "ok", "url": "https://…", "filename": "….mp4", "height": 720, "muxed": false}
```

A refusal comes back as `{"status": "error", "error": {"code": …, "message": …}}`, and the app
shows that message as it stands — so what you write there is what your users read.

`GET /media?v=…&h=…&e=…&s=…` — the muxed stream. Time-limited, and signed when a token is set.
`GET /health` — liveness, and what the settings currently are.

## Tests

```sh
python3 test_server.py
```

Offline and stubbed: no yt-dlp, no network, no YouTube. They cover routing, auth, format choice,
and the signing and expiry of `/media` links — this server's own work, rather than yt-dlp's.

## One thing worth being clear about

Downloading from YouTube is outside what its terms allow, whoever fetches it. Keeping a personal
copy of something you can already watch is the ordinary case for it. Running this where other
people can use it is a different thing: you stop being someone keeping personal copies and become
the operator of a service reproducing other people's work for third parties, which is not covered
by any private-copying exception. Set a token, and keep it to yourself and people you'd vouch for.
