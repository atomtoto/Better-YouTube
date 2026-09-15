#!/usr/bin/env python3
"""A resolver for Better YouTube's download feature.

The app plays video through YouTube's embed, which never exposes a media file, so it cannot
download one by itself. This is the piece that resolves one for it: it speaks the app's JSON
shape, and does the extracting with yt-dlp — the tool that is actually maintained against
YouTube's changes, which is the whole reason to run this rather than trust a public service.

Two paths, and the difference matters for what this costs you to run:

  * **Direct.** When YouTube offers a progressive stream (video and audio already in one file) at
    or below the wanted height, the answer is that stream's own CDN URL. The phone fetches it
    straight from Google. This server moves no video at all — it only answers a question.

  * **Muxed.** Above roughly 360p, YouTube usually keeps video and audio apart, and the app plays
    a single file. So the answer is a URL back to `/media` here, which re-resolves and pipes both
    streams through ffmpeg into a fragmented MP4 as it goes. That one *does* run through this
    server, so it costs bandwidth — but it streams rather than staging to disk, so it needs no
    storage and starts immediately.

Deliberately stdlib-only apart from yt-dlp: nothing to keep up to date but the one thing that
needs keeping up to date.

Environment:
  PORT            port to listen on (default 8080)
  PUBLIC_URL      the address the *phone* reaches this on, e.g. https://box.example.com.
                  Required for muxed downloads: it is what /media links are built from, and
                  without it they come out pointing at this container's own localhost.
  RESOLVER_TOKEN  if set, POST / requires it (Bearer or Api-Key), and /media links are signed
  MAX_HEIGHT      hard ceiling on resolution regardless of what the app asks (default 1080)
  ALLOW_MUX       set to 0 to refuse anything needing muxing, keeping this server bandwidth-free
"""

import hashlib
import hmac
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8080"))
PUBLIC_URL = os.environ.get("PUBLIC_URL", "").rstrip("/")
TOKEN = os.environ.get("RESOLVER_TOKEN", "")
MAX_HEIGHT = int(os.environ.get("MAX_HEIGHT", "1080"))
ALLOW_MUX = os.environ.get("ALLOW_MUX", "1") not in ("0", "false", "no")

# How long a /media link stays valid. Long enough to survive a queue of downloads, short enough
# that a link that leaks is not a standing invitation.
LINK_TTL = 6 * 60 * 60

VIDEO_ID = re.compile(r"^[A-Za-z0-9_-]{11}$")


# --------------------------------------------------------------------------- extraction

def extract(video_id):
    """Everything yt-dlp knows about a video, without downloading any of it."""
    from yt_dlp import YoutubeDL

    options = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        # The app only ever asks for one video; a link that turns out to be a playlist should
        # resolve to its first entry rather than several minutes of metadata.
        "noplaylist": True,
    }
    with YoutubeDL(options) as ydl:
        return ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=False)


def progressive_format(info, max_height):
    """The best already-muxed stream at or below `max_height`, if YouTube offers one.

    This is the cheap answer: one file, playable as is, fetched by the phone straight from
    Google's CDN. MP4 is preferred over WebM because it is what AVPlayer takes without argument.
    """
    candidates = []
    for f in info.get("formats") or []:
        if f.get("vcodec") in (None, "none") or f.get("acodec") in (None, "none"):
            continue
        if not f.get("url"):
            continue
        height = f.get("height") or 0
        if height > max_height:
            continue
        candidates.append(f)

    if not candidates:
        return None
    candidates.sort(key=lambda f: (f.get("ext") == "mp4", f.get("height") or 0, f.get("tbr") or 0))
    return candidates[-1]


def split_formats(info, max_height):
    """The best video-only and audio-only pair to hand ffmpeg."""
    videos, audios = [], []
    for f in info.get("formats") or []:
        if not f.get("url"):
            continue
        has_video = f.get("vcodec") not in (None, "none")
        has_audio = f.get("acodec") not in (None, "none")
        if has_video and not has_audio:
            if (f.get("height") or 0) <= max_height:
                videos.append(f)
        elif has_audio and not has_video:
            audios.append(f)

    if not videos or not audios:
        return None, None
    # avc1 and m4a first: they go into an MP4 container by copy, with nothing to re-encode.
    videos.sort(key=lambda f: (
        str(f.get("vcodec", "")).startswith("avc"), f.get("height") or 0, f.get("tbr") or 0
    ))
    audios.sort(key=lambda f: (f.get("ext") == "m4a", f.get("abr") or 0))
    return videos[-1], audios[-1]


# --------------------------------------------------------------------------- signed links

def sign(video_id, height, expires):
    payload = f"{video_id}:{height}:{expires}".encode()
    return hmac.new(TOKEN.encode(), payload, hashlib.sha256).hexdigest()[:32]


def media_link(video_id, height):
    expires = int(time.time()) + LINK_TTL
    query = {"v": video_id, "h": height, "e": expires}
    if TOKEN:
        query["s"] = sign(video_id, height, expires)
    base = PUBLIC_URL or f"http://localhost:{PORT}"
    return f"{base}/media?{urllib.parse.urlencode(query)}"


def link_is_valid(params):
    try:
        expires = int(params.get("e", ["0"])[0])
    except ValueError:
        return False
    if expires < time.time():
        return False
    if not TOKEN:
        return True
    given = params.get("s", [""])[0]
    expected = sign(params.get("v", [""])[0], params.get("h", ["0"])[0], expires)
    return hmac.compare_digest(given, expected)


# --------------------------------------------------------------------------- HTTP

class Handler(BaseHTTPRequestHandler):
    server_version = "BetterYouTubeResolver/1.0"
    # The extractor, swappable so the HTTP layer can be tested without touching YouTube.
    extractor = staticmethod(extract)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    # -- helpers

    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status, code, message):
        # The shape the app reads a refusal out of: it reports `error.message` in the service's
        # own words rather than a generic failure, so this is what the user ends up seeing.
        self.send_json(status, {"status": "error", "error": {"code": code, "message": message}})

    def authorized(self):
        if not TOKEN:
            return True
        header = self.headers.get("Authorization", "")
        # Accept both spellings; the app sends a bare token as Bearer and one typed with its own
        # scheme verbatim.
        for prefix in ("Bearer ", "Api-Key "):
            if header.startswith(prefix) and hmac.compare_digest(header[len(prefix):], TOKEN):
                return True
        return False

    @staticmethod
    def wanted_height(body):
        """The app says the wanted height under several names; any of them will do."""
        for key in ("maxHeight", "videoQuality", "quality", "height"):
            value = body.get(key)
            if value is None:
                continue
            try:
                return max(144, min(MAX_HEIGHT, int(str(value))))
            except ValueError:
                continue
        return MAX_HEIGHT

    @staticmethod
    def video_id(body):
        given = str(body.get("videoId") or "").strip()
        if VIDEO_ID.match(given):
            return given
        url = str(body.get("url") or "")
        for pattern in (r"[?&]v=([A-Za-z0-9_-]{11})", r"youtu\.be/([A-Za-z0-9_-]{11})",
                        r"/(?:embed|shorts|live)/([A-Za-z0-9_-]{11})"):
            found = re.search(pattern, url)
            if found:
                return found.group(1)
        return None

    # -- routes

    def do_GET(self):
        path, _, raw_query = self.path.partition("?")
        if path == "/health":
            return self.send_json(200, {"status": "ok", "mux": ALLOW_MUX, "maxHeight": MAX_HEIGHT})
        if path == "/media":
            return self.serve_media(urllib.parse.parse_qs(raw_query))
        return self.send_error_json(404, "not_found", "Nothing here. The app posts to /.")

    def do_POST(self):
        if self.path.partition("?")[0] not in ("/", "/resolve"):
            return self.send_error_json(404, "not_found", "Nothing here. The app posts to /.")
        if not self.authorized():
            return self.send_error_json(401, "unauthorized", "Wrong or missing token.")

        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, TypeError):
            return self.send_error_json(400, "bad_request", "That wasn't JSON.")
        if not isinstance(body, dict):
            return self.send_error_json(400, "bad_request", "Expected a JSON object.")

        video_id = self.video_id(body)
        if not video_id:
            return self.send_error_json(400, "bad_url", "No YouTube video id in that request.")
        height = self.wanted_height(body)

        try:
            info = self.extractor(video_id)
        except Exception as error:  # yt-dlp raises a family of these; the message is the useful part
            return self.send_error_json(502, "extract_failed", str(error).strip() or "yt-dlp couldn't read that video.")

        chosen = progressive_format(info, height)
        if chosen:
            return self.send_json(200, {
                "status": "ok",
                "url": chosen["url"],
                "filename": f"{video_id}.{chosen.get('ext') or 'mp4'}",
                "height": chosen.get("height"),
                "size": chosen.get("filesize") or chosen.get("filesize_approx"),
                "muxed": False,
            })

        if not ALLOW_MUX:
            return self.send_error_json(409, "needs_mux", (
                "YouTube only offers this one as separate video and audio streams, and this "
                "resolver is set not to join them. Ask for a lower quality, or set ALLOW_MUX=1."
            ))
        video, audio = split_formats(info, height)
        if not video or not audio:
            return self.send_error_json(404, "no_format", "No usable stream at or below that height.")
        if not shutil.which("ffmpeg"):
            return self.send_error_json(500, "no_ffmpeg", "This one needs joining and ffmpeg isn't installed here.")

        return self.send_json(200, {
            "status": "ok",
            "url": media_link(video_id, video.get("height") or height),
            "filename": f"{video_id}.mp4",
            "height": video.get("height"),
            "muxed": True,
        })

    def serve_media(self, params):
        if not link_is_valid(params):
            return self.send_error_json(403, "bad_link", "That download link has expired.")
        video_id = params.get("v", [""])[0]
        if not VIDEO_ID.match(video_id):
            return self.send_error_json(400, "bad_url", "Not a video id.")
        try:
            height = min(MAX_HEIGHT, int(params.get("h", [str(MAX_HEIGHT)])[0]))
        except ValueError:
            height = MAX_HEIGHT

        # Re-resolved now rather than carried in the link: YouTube's media URLs are short-lived,
        # and one minted at resolve time would often be dead by the time the queue reaches it.
        try:
            info = self.extractor(video_id)
        except Exception as error:
            return self.send_error_json(502, "extract_failed", str(error).strip())

        video, audio = split_formats(info, height)
        if not video or not audio:
            return self.send_error_json(404, "no_format", "No usable stream at or below that height.")

        # `frag_keyframe+empty_moov` is what makes an MP4 writable to a pipe: an ordinary one puts
        # its index at the end, which needs a seekable output. A fragmented one plays fine in
        # AVPlayer and starts arriving immediately.
        command = [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", video["url"], "-i", audio["url"],
            "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-f", "mp4", "pipe:1",
        ]

        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        # No Content-Length: the size isn't known until it has all been muxed. The app shows a
        # bar without a percentage in that case rather than a wrong one.
        self.send_header("Content-Disposition", f'attachment; filename="{video_id}.mp4"')
        self.end_headers()

        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            shutil.copyfileobj(process.stdout, self.wfile, length=256 * 1024)
        except (BrokenPipeError, ConnectionResetError):
            # The phone hung up — a cancelled or paused download. Nothing to report.
            pass
        finally:
            process.stdout.close()
            process.terminate()
            process.wait(timeout=10)


def main():
    if not PUBLIC_URL and ALLOW_MUX:
        sys.stderr.write(
            "warning: PUBLIC_URL is not set. Downloads that need joining will be handed links "
            "pointing at localhost, which the phone cannot reach. Set PUBLIC_URL to the address "
            "you reach this server on.\n"
        )
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    sys.stderr.write(f"resolver listening on :{PORT}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
