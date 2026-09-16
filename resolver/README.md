# Better YouTube — download resolver

The app plays video through YouTube's embed, which never exposes a media file, so it cannot
download one by itself. This is the piece that resolves one for it.

It is about 400 lines of Python standard library around **yt-dlp**, which does the actual
extracting. That split is the point: yt-dlp is maintained against YouTube's changes by people who
do it full time, and it is the only part of this that needs keeping current. The container
refreshes it on every start, so "it stopped working" is usually fixed by a restart.

## The short way

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/atomtoto/Better-YouTube)

1. Click the button, sign in with GitHub, confirm. Two minutes.
2. When it is live, open the service's URL **on the phone**.
3. Tap **Set up Better YouTube**.

That is the whole thing. No terminal, no Docker, no IP addresses, and no typing an access token —
Render generates one, and the resolver's own setup page hands it to the app, which asks you to
confirm before saving it.

The setup page closes about **30 minutes after the service starts**, because it shows that token
and the address it lives at is a guessable subdomain. Restart the service to open it again.

## The other ways

**Fly.io**, from this directory:

```sh
fly launch --copy-config --no-deploy
fly secrets set RESOLVER_TOKEN=$(openssl rand -hex 16)
fly deploy
```

**Railway**: point it at this repository; `railway.json` is picked up. Set `RESOLVER_TOKEN`
yourself in the dashboard.

**Your own machine**, which is the only one where nothing leaves the house:

```sh
docker compose up -d
curl localhost:8080/health
```

Then open `http://<your-machine's-LAN-address>:8080` on the phone and tap the button. Set
`RESOLVER_TOKEN` in `.env` first if the port is reachable from anywhere you don't control.

Without Docker: `pip install yt-dlp`, install `ffmpeg`, then `python3 server.py`.

## What it costs to run

Two paths, and they are very different for you:

| | When | Bandwidth through this server |
| --- | --- | --- |
| **Direct** | YouTube offers the wanted height already joined (in practice, 360p and sometimes 720p) | **None.** The phone is handed YouTube's own CDN URL and fetches it from Google. |
| **Muxed** | Anything higher — YouTube keeps video and audio apart above 360p, and the app plays one file | All of it. `/media` re-resolves and pipes both streams through ffmpeg into a fragmented MP4 as they arrive. |

Nothing is ever written to disk: the muxed path streams. `ALLOW_MUX=0` refuses it entirely, and
then this server never carries a byte of video — downloads are capped at whatever YouTube happens
to offer already joined. On a free hosting tier that is worth considering.

## Settings

Every one of these has a working default. The list is short on purpose.

| Variable | Meaning |
| --- | --- |
| `RESOLVER_TOKEN` | If set, `POST /` needs it and `/media` links are signed with it. **Set this** on anything reachable from the internet; without it, whoever finds the address can use it. |
| `MAX_HEIGHT` | Ceiling regardless of what the app asks for. `720` keeps the muxed path cheaper. |
| `ALLOW_MUX` | `0` refuses anything needing ffmpeg. |
| `SETUP_MINUTES` | How long the setup page stays open after boot. `0` turns it off. |
| `UPDATE_YTDLP` | `0` skips the update on boot. |
| `PORT` | Default 8080. |
| `PUBLIC_URL` | **Normally leave this alone.** The server reads its own address off each request, so it is right whether it is reached at a LAN address, through a tunnel, or at a hosting platform's domain. This is only an override for the rare setup where neither the `Host` nor the `X-Forwarded-*` headers tell the truth. |

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

`GET /` — the setup page, while its window is open.
`GET /media?v=…&h=…&e=…&s=…` — the muxed stream. Time-limited, and signed when a token is set.
`GET /health` — liveness, and what the settings currently are.

## Tests

```sh
python3 test_server.py
```

Offline and stubbed: no yt-dlp, no network, no YouTube. They cover this server's own work —
routing, auth, format choice, the address it derives from a request, and the signing and expiry of
its links — rather than yt-dlp's.

## One thing worth being clear about

Downloading from YouTube is outside what its terms allow, whoever fetches it. Keeping a personal
copy of something you can already watch is the ordinary case for it. Running this where other
people can use it is a different thing: you stop being someone keeping personal copies and become
the operator of a service reproducing other people's work for third parties, which no
private-copying exception covers. Keep the token to yourself and to people you would vouch for.
