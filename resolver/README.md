# Better YouTube — download resolver

The app plays video through YouTube's embed, which never exposes a media file, so it cannot
download one by itself. This is the piece that resolves one for it.

It is about 400 lines of Python standard library around **yt-dlp**, which does the actual
extracting. That split is the point: yt-dlp is maintained against YouTube's changes by people who
do it full time, and it is the only part of this that needs keeping current. The container
refreshes it on every start, so "it stopped working" is usually fixed by a restart.

## Where to run it

**Run it on your own network.** Not a preference — YouTube distrusts datacenter IP ranges, and a
resolver at a hosting provider is usually met with *"Sign in to confirm you're not a bot"* instead
of a video. No setting here talks it round, because nothing is wrong: YouTube has decided that
address looks automated, and at a cloud provider it is not entirely wrong. A home connection is an
ordinary residential address and is simply not treated that way.

```sh
docker compose up -d
curl localhost:8080/health
```

Then open `http://<your-machine's-LAN-address>:8080` on the phone and tap **Set up Better
YouTube**. That is the whole setup: no typing, and no token to copy — the page hands it over and
the app asks you to confirm.

Set `RESOLVER_TOKEN` in `.env` first if that port is reachable from anywhere you do not control.
Without Docker: `pip install yt-dlp`, install `ffmpeg`, then `python3 server.py`.

To reach it from outside the house, put it behind Tailscale or a Cloudflare Tunnel. Both keep the
requests going out over your home connection, which is the part that matters here.

## Hosting it instead, and why it often fails

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy?repo=https://github.com/atomtoto/Better-YouTube)

`render.yaml` pins Render's **free** plan — leaving that line out bills the default paid tier at
$7/month — and `generateValue` mints an access token nobody has to type. `fly.toml` and
`railway.json` cover the other two:

```sh
fly launch --copy-config --no-deploy
fly secrets set RESOLVER_TOKEN=$(openssl rand -hex 16)
fly deploy
```

**Expect the bot check.** It is the common outcome from any of these, and the resolver says so in
those words rather than passing yt-dlp's flags and wiki links to a phone screen. Two ways round
it, neither free:

- `COOKIES_FILE` pointed at an exported cookies file makes the requests authenticated. They then
  belong to that YouTube account — and using an account from a datacenter address is a good way to
  get it limited. Use a throwaway account if you use one at all.
- `PLAYER_CLIENT` passes yt-dlp a different client to try. Worth touching only when a yt-dlp issue
  thread names one; it is a moving target by nature.

If you are weighing those against plugging a machine in at home, plug the machine in at home.

Free hosting has a second catch even when it works: the service sleeps after about 15 minutes idle
and takes a minute to wake, and its **bandwidth is counted** — which is the muxed path's bill, not
the direct one. Check any host's current pricing yourself; free tiers change.

The setup page closes once a download has worked, and otherwise about 30 minutes after the service
starts, because it shows the access token and the address it sits at is a guessable subdomain. Both
conditions are needed rather than just the timer: a sleeping instance restarts that clock every
time it wakes. Restart the service to open it again.

## What it costs to run

Two paths, and they are very different for you:

| | When | Bandwidth through this server |
| --- | --- | --- |
| **Direct** | YouTube offers the wanted height already joined (in practice, 360p and sometimes 720p) | **None.** The phone is handed YouTube's own CDN URL and fetches it from Google. |
| **Muxed** | Anything higher — YouTube keeps video and audio apart above 360p, and the app plays one file | All of it. `/media` re-resolves and pipes both streams through ffmpeg into a fragmented MP4 as they arrive. |

Nothing is ever written to disk: the muxed path streams. `ALLOW_MUX=0` refuses it entirely, and
then this server never carries a byte of video — downloads are capped at whatever YouTube happens
to offer already joined.

At home this is barely a decision: the bandwidth is already yours. It only bites on hosting, where
a muxed 1080p video is hundreds of megabytes against a monthly allowance and the direct path is
zero.

## Settings

Every one of these has a working default. The list is short on purpose.

| Variable | Meaning |
| --- | --- |
| `RESOLVER_TOKEN` | If set, `POST /` needs it and `/media` links are signed with it. **Set this** on anything reachable from the internet; without it, whoever finds the address can use it. |
| `MAX_HEIGHT` | Ceiling regardless of what the app asks for. `720` keeps the muxed path cheaper. |
| `ALLOW_MUX` | `0` refuses anything needing ffmpeg. |
| `SETUP_MINUTES` | How long the setup page stays open after boot. `0` turns it off. |
| `COOKIES_FILE` | Path to an exported cookies file, for when YouTube demands a sign-in. The downloads become that account's — read the warning above. |
| `PLAYER_CLIENT` | Comma-separated yt-dlp player clients to try, e.g. `ios,web`. Only when a yt-dlp thread tells you to. |
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
