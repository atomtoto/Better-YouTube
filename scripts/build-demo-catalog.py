#!/usr/bin/env python3
"""Builds the demo mode's catalogue: BetterYouTube/BetterYouTube/DemoCatalog.json.

The demo shows real, public videos — they play through YouTube's own embed, which needs no key —
with everything else the app shows about them taken from this file: titles, descriptions,
lengths, dates, view counts, channels and playlists. Openly licensed channels were picked on
purpose (Blender's open movies, NASA, CNES, NoCopyrightSounds, MIT OpenCourseWare).

The facts are read once, here, from the videos' public pages, so the app needs neither a key nor
a scraper of its own. Run it again to refresh the catalogue; the numbers are a snapshot of the
day it ran.

Usage: scripts/build-demo-catalog.py
"""
import datetime
import html
import json
import pathlib
import re
import subprocess
import sys
import time

OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "BetterYouTube" / "BetterYouTube" / "DemoCatalog.json"

# Each channel's most recent uploads, by handle.
CHANNELS = [
    ("BlenderOfficial", 6),
    ("BlenderStudio", 6),
    ("NASA", 8),
    ("CNESFrance", 6),
    ("NoCopyrightSounds", 8),
    ("mitocw", 6),
]
# Playlists to carry over whole, by their title on the channel's Playlists tab.
PLAYLISTS = [
    ("BlenderStudio", "Blender Open Movies", 12),
]
# Videos worth having whatever the channels uploaded lately.
EXTRA_VIDEOS = [
    "aqz-KE-bpKQ",  # Big Buck Bunny, Blender
    "jNQXAC9IVRw",  # Me at the zoo, the first video on YouTube
]

# Videos left out whatever the channel: a demo shows the app, so it stays clear of politics.
EXCLUDED_VIDEOS = {
    "1icdW32gS8A",  # NASA: a call from the President to the Space Station
}

CATEGORIES = {
    "Film & Animation": "1", "Autos & Vehicles": "2", "Music": "10", "Pets & Animals": "15",
    "Sports": "17", "Travel & Events": "19", "Gaming": "20", "People & Blogs": "22",
    "Comedy": "23", "Entertainment": "24", "News & Politics": "25", "Howto & Style": "26",
    "Education": "27", "Science & Technology": "28", "Nonprofits & Activism": "29",
}

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 "
                  "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Accept-Language": "en-US,en;q=0.9",
    # Past the EU consent page, which otherwise stands in for every page.
    "Cookie": "SOCS=CAI; CONSENT=YES+1",
}


def fetch(url: str) -> str:
    # The system's curl, which trusts what macOS trusts — a python.org Python ships without
    # certificates of its own until its installer's extra step has been run.
    time.sleep(0.4)
    command = ["curl", "--silent", "--show-error", "--fail", "--location", "--max-time", "30", url]
    for name, value in HEADERS.items():
        command += ["--header", f"{name}: {value}"]
    for attempt in range(3):
        result = subprocess.run(command, capture_output=True)
        if result.returncode == 0:
            return result.stdout.decode("utf-8", errors="replace")
        time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"Couldn't fetch {url}: {result.stderr.decode(errors='replace').strip()}")


def page_json(url: str, name: str) -> dict:
    """The JSON a YouTube page embeds under `name`. Now and then YouTube answers with a page that
    has none — a check of its own, by the look of it — and asking again gets the real one."""
    for attempt in range(4):
        match = re.search(rf"{name}\s*=\s*(\{{.+?\}});(?:var |</script>)", fetch(url), re.S)
        if match:
            return json.loads(match.group(1))
        time.sleep(3 * (attempt + 1))
    raise ValueError(f"{name} not found in {url}")


def walk(node, key: str):
    """Every value under `key`, anywhere in a JSON tree."""
    if isinstance(node, dict):
        for name, value in node.items():
            if name == key:
                yield value
            yield from walk(value, key)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value, key)


def count(text: str | None) -> int | None:
    """'577K' → 577000, '1.2M' → 1200000, '285' → 285."""
    if not text:
        return None
    text = text.replace(",", "")
    scale = {"K": 1_000, "M": 1_000_000, "B": 1_000_000_000}.get(text[-1:], 1)
    number = float(text[:-1] if scale > 1 else text)
    return int(number * scale)


def channel(path: str) -> tuple[dict, list[str]]:
    """A channel's details, and its latest uploads, newest first."""
    data = page_json(f"https://www.youtube.com/{path}/videos", "var ytInitialData")
    meta = data["metadata"]["channelMetadataRenderer"]
    flat = json.dumps(data)
    subscribers = re.search(r'"content": "([\d.,]+[KMB]?) subscribers"', flat)
    videos = re.search(r'"content": "([\d.,]+[KMB]?) videos"', flat)
    handle = re.search(r'"content": "(@[\w.-]+)"', flat)
    uploads: list[str] = []
    for video_id in re.findall(r'"videoId": "([\w-]{11})"', flat):
        if video_id not in uploads:
            uploads.append(video_id)
    return {
        "id": meta["externalId"],
        "title": meta["title"],
        "handle": handle.group(1) if handle else "",
        "description": meta.get("description", "")[:1000],
        "avatar": meta["avatar"]["thumbnails"][0]["url"],
        "subscribers": count(subscribers.group(1) if subscribers else None),
        "videoCount": count(videos.group(1) if videos else None),
    }, uploads


def playlist_id(handle: str, title: str) -> str:
    data = page_json(f"https://www.youtube.com/@{handle}/playlists", "var ytInitialData")
    for lockup in walk(data, "lockupViewModel"):
        titles = list(walk(lockup.get("metadata", {}), "content"))
        if lockup.get("contentId", "").startswith("PL") and titles and titles[0] == title:
            return lockup["contentId"]
    raise ValueError(f"No playlist called {title!r} on @{handle}")


def playlist(list_id: str, limit: int) -> dict:
    data = page_json(f"https://www.youtube.com/playlist?list={list_id}", "var ytInitialData")
    meta = data["metadata"]["playlistMetadataRenderer"]
    flat = json.dumps(data)
    # The page holds the playlist's own entries and little else; each appears a few times over.
    ids = list(dict.fromkeys(re.findall(r'"videoId": "([\w-]{11})"', flat)))
    return {"id": list_id, "title": meta["title"], "description": meta.get("description", ""), "videoIds": ids[:limit]}


def video(video_id: str, allows_short: bool = False) -> dict | None:
    player = page_json(f"https://www.youtube.com/watch?v={video_id}", "ytInitialPlayerResponse")
    details = player.get("videoDetails", {})
    micro = player.get("microformat", {}).get("playerMicroformatRenderer", {})
    playable = player.get("playabilityStatus", {})
    length = int(details.get("lengthSeconds", "0"))
    # Only what the app can actually play: an embeddable video, not live — and, from a channel's
    # uploads, not a Short. A video named on purpose may be short: "Me at the zoo" is 19 seconds.
    if playable.get("status") != "OK" or not playable.get("playableInEmbed", False):
        return None
    if length < (1 if allows_short else 61) or details.get("isLive") or details.get("isUpcoming"):
        return None
    thumbnails = [t["url"] for t in details.get("thumbnail", {}).get("thumbnails", [])]
    published = micro.get("publishDate") or micro.get("uploadDate")
    published_utc = datetime.datetime.fromisoformat(published).astimezone(datetime.timezone.utc)
    minutes, seconds = divmod(length, 60)
    hours, minutes = divmod(minutes, 60)
    duration = "PT" + (f"{hours}H" if hours else "") + (f"{minutes}M" if minutes else "") + f"{seconds}S"
    return {
        "id": video_id,
        "title": html.unescape(details["title"]),
        "channelId": details["channelId"],
        "description": details.get("shortDescription", "")[:1500],
        "publishedAt": published_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "duration": duration,
        "views": int(details.get("viewCount", "0")),
        "categoryId": CATEGORIES.get(micro.get("category", ""), "22"),
        "hasMaxres": any("maxresdefault" in url for url in thumbnails),
    }


def main() -> None:
    channels: dict[str, dict] = {}
    wanted: list[str] = []
    playlists: list[dict] = []

    for handle, recent in CHANNELS:
        details, uploads = channel(f"@{handle}")
        channels[details["id"]] = details
        details["recent"] = uploads[: recent * 2]  # Spares, for the ones that can't be played.
        details["recentWanted"] = recent
        print(f"{details['title']}: {len(uploads)} uploads listed", file=sys.stderr)

    for handle, title, limit in PLAYLISTS:
        found = playlist(playlist_id(handle, title), limit)
        playlists.append(found)
        print(f"Playlist {found['title']}: {len(found['videoIds'])} videos", file=sys.stderr)

    videos: dict[str, dict] = {}

    def add(video_id: str, allows_short: bool = False) -> bool:
        if video_id in videos:
            return True
        if video_id in EXCLUDED_VIDEOS:
            return False
        try:
            found = video(video_id, allows_short)
        except Exception as error:  # A page that won't parse is a video left out, not a failure.
            print(f"  skipped {video_id}: {error}", file=sys.stderr)
            return False
        if found is None:
            print(f"  skipped {video_id}: not playable in the app", file=sys.stderr)
            return False
        videos[video_id] = found
        return True

    for details in channels.values():
        added = 0
        for video_id in details.pop("recent"):
            if added == details["recentWanted"]:
                break
            added += add(video_id)
        details.pop("recentWanted")

    for found in playlists:
        found["videoIds"] = [video_id for video_id in found["videoIds"] if add(video_id)]
    for video_id in EXTRA_VIDEOS:
        add(video_id, allows_short=True)

    # Every video's channel, including those of extras and playlist entries from elsewhere.
    for found in list(videos.values()):
        if found["channelId"] not in channels:
            details, _ = channel(f"channel/{found['channelId']}")
            channels[details["id"]] = details

    catalogue = {
        "generatedAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "channels": sorted(channels.values(), key=lambda c: c["title"].lower()),
        "videos": sorted(videos.values(), key=lambda v: v["publishedAt"], reverse=True),
        "playlists": playlists,
    }
    OUTPUT.write_text(json.dumps(catalogue, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {len(videos)} videos, {len(channels)} channels, {len(playlists)} playlists to {OUTPUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
