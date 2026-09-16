#!/usr/bin/env python3
"""Tests for the resolver's HTTP layer.

The extractor is stubbed throughout, so these run offline, in a second, without yt-dlp installed
and without asking YouTube for anything. What they cover is the part that is actually this
server's own work: routing, auth, reading the height out of whichever name the app used, picking
a format, and signing and expiring the /media links.

    python3 test_server.py
"""
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

os.environ.setdefault("PUBLIC_URL", "https://box.example.com")
os.environ.setdefault("RESOLVER_TOKEN", "s3cret")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import server  # noqa: E402

PROGRESSIVE = {"formats": [
    {"url": "https://cdn/360.mp4", "vcodec": "avc1", "acodec": "mp4a", "height": 360, "ext": "mp4", "filesize": 1234},
    {"url": "https://cdn/720.mp4", "vcodec": "avc1", "acodec": "mp4a", "height": 720, "ext": "mp4"},
    {"url": "https://cdn/1080v.mp4", "vcodec": "avc1", "acodec": "none", "height": 1080, "ext": "mp4"},
    {"url": "https://cdn/a.m4a", "vcodec": "none", "acodec": "mp4a", "ext": "m4a", "abr": 128},
]}
SPLIT_ONLY = {"formats": [
    {"url": "https://cdn/1080v.mp4", "vcodec": "avc1", "acodec": "none", "height": 1080, "ext": "mp4"},
    {"url": "https://cdn/a.m4a", "vcodec": "none", "acodec": "mp4a", "ext": "m4a", "abr": 128},
]}

PORT = 8137
state = {"info": PROGRESSIVE}
failures = []


class StubHandler(server.Handler):
    extractor = staticmethod(lambda video_id: state["info"])


def call(path="/", body=None, token="s3cret", method="POST", headers=None):
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method=method)
    if body is not None:
        request.data = json.dumps(body).encode()
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.loads(error.read())
        except ValueError:
            return error.code, {}


def get_text(path="/", headers=None):
    """A page rather than an API answer, so this one keeps the body as text."""
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}{path}", method="GET")
    for name, value in (headers or {}).items():
        request.add_header(name, value)
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def check(name, got, want):
    if got == want:
        print(f"  ok    {name}")
    else:
        print(f"  FAIL  {name}: got {got!r}, want {want!r}")
        failures.append(name)


def main():
    # The image installs ffmpeg; without this the mux path would correctly refuse and the tests
    # below would be testing that refusal instead of the thing they mean to.
    server.shutil.which = lambda name: "/usr/bin/ffmpeg"

    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), StubHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()

    print("auth")
    check("no token is refused", call(token=None, body={"videoId": "dQw4w9WgXcQ"})[0], 401)
    check("wrong token is refused", call(token="nope", body={"videoId": "dQw4w9WgXcQ"})[0], 401)

    print("a progressive stream is answered with its own CDN url")
    status, reply = call(body={"videoId": "dQw4w9WgXcQ", "videoQuality": "720"})
    check("status", status, 200)
    check("picks the best muxed stream at the cap", reply.get("url"), "https://cdn/720.mp4")
    check("says it needs no joining", reply.get("muxed"), False)

    status, reply = call(body={"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "maxHeight": 360})
    check("a lower cap picks a lower stream", reply.get("url"), "https://cdn/360.mp4")
    check("size is passed through when known", reply.get("size"), 1234)

    print("the video id is found wherever it is")
    check("youtu.be", call(body={"url": "https://youtu.be/dQw4w9WgXcQ"})[0], 200)
    check("shorts", call(body={"url": "https://www.youtube.com/shorts/dQw4w9WgXcQ"})[0], 200)
    check("no id at all is refused", call(body={"url": "https://example.com/nope"})[0], 400)

    print("split streams fall back to a link back here")
    state["info"] = SPLIT_ONLY
    status, reply = call(body={"videoId": "dQw4w9WgXcQ", "maxHeight": 1080})
    check("status", status, 200)
    check("says it needs joining", reply.get("muxed"), True)
    check("height is reported", reply.get("height"), 1080)
    check(
        "link is public and signed",
        reply.get("url", "").startswith("https://box.example.com/media?") and "s=" in reply.get("url", ""),
        True,
    )

    link = reply["url"].split("https://box.example.com")[1]
    tampered = link[:-1] + ("0" if link[-1] != "0" else "1")
    check("a tampered signature is refused", call(tampered, method="GET", token=None)[0], 403)
    check("an expired link is refused", call("/media?v=dQw4w9WgXcQ&h=1080&e=1&s=x", method="GET", token=None)[0], 403)

    original_token = server.TOKEN
    server.TOKEN = ""
    check("an unsigned link still expires", call("/media?v=dQw4w9WgXcQ&h=720&e=1", method="GET", token=None)[0], 403)
    server.TOKEN = original_token

    print("muxing can be switched off entirely")
    server.ALLOW_MUX = False
    check(
        "it says so rather than failing vaguely",
        call(body={"videoId": "dQw4w9WgXcQ"})[1].get("error", {}).get("code"),
        "needs_mux",
    )
    server.ALLOW_MUX = True
    state["info"] = PROGRESSIVE

    print("the address is read off the request, not configured")
    original_public = server.PUBLIC_URL
    server.PUBLIC_URL = ""
    state["info"] = SPLIT_ONLY

    _, reply = call(body={"videoId": "dQw4w9WgXcQ"}, headers={"Host": "192.168.1.20:8080"})
    check(
        "a LAN Host header becomes the link's base",
        reply.get("url", "").startswith("http://192.168.1.20:8080/media?"),
        True,
    )

    _, reply = call(body={"videoId": "dQw4w9WgXcQ"}, headers={
        "Host": "internal:8080",
        "X-Forwarded-Host": "resolver.fly.dev",
        "X-Forwarded-Proto": "https",
    })
    check(
        "a proxy's forwarded host wins over the internal one",
        reply.get("url", "").startswith("https://resolver.fly.dev/media?"),
        True,
    )

    _, reply = call(body={"videoId": "dQw4w9WgXcQ"}, headers={
        "Host": "internal:8080",
        "X-Forwarded-Host": "a.fly.dev, b.internal",
        "X-Forwarded-Proto": "https, http",
    })
    check(
        "a proxy chain uses the client-facing entry",
        reply.get("url", "").startswith("https://a.fly.dev/media?"),
        True,
    )

    check(
        "PUBLIC_URL still overrides when set",
        (lambda: (setattr(server, "PUBLIC_URL", "https://forced.example"),
                  call(body={"videoId": "dQw4w9WgXcQ"}, headers={"Host": "ignored"})[1]
                  .get("url", "").startswith("https://forced.example/media?"))[1])(),
        True,
    )
    server.PUBLIC_URL = ""
    state["info"] = PROGRESSIVE

    print("the setup page configures the app in one tap")
    status, page = get_text("/", headers={"Host": "resolver.fly.dev", "X-Forwarded-Proto": "https"})
    check("it is served", status, 200)
    check(
        "it carries a link the app understands",
        "betteryoutube://downloads?endpoint=https%3A%2F%2Fresolver.fly.dev" in page,
        True,
    )
    check("the token rides along so nobody types it", "token=s3cret" in page, True)

    original_started = server.STARTED_AT
    server.STARTED_AT = original_started - (server.SETUP_MINUTES * 60 + 1)
    status, page = get_text("/")
    check("it closes on a timer", status, 403)
    check("and says the resolver itself is fine", "running normally" in page, True)
    server.STARTED_AT = original_started

    original_minutes = server.SETUP_MINUTES
    server.SETUP_MINUTES = 0
    check("0 disables it entirely", get_text("/")[0], 403)
    server.SETUP_MINUTES = original_minutes
    server.PUBLIC_URL = original_public

    print("the rest")
    check("health", call("/health", method="GET", token=None)[1].get("status"), "ok")
    check("a body that isn't json is refused", call(body=None, method="POST")[0], 400)
    check("an unknown path is refused", call("/nope", body={}, method="POST")[0], 404)

    httpd.shutdown()
    print()
    if failures:
        print(f"{len(failures)} failed: {', '.join(failures)}")
        return 1
    print("all pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
