#!/bin/sh
# yt-dlp is the one moving part here: YouTube changes, yt-dlp is updated within days, and a
# months-old copy is the usual reason a resolver that "used to work" stops. So it is refreshed on
# every start — best effort, because a container that won't boot without the network is worse
# than one running last week's version.
if [ "${UPDATE_YTDLP:-1}" != "0" ]; then
    echo "updating yt-dlp…" >&2
    pip install --quiet --no-cache-dir --upgrade --user yt-dlp 2>/dev/null \
        || echo "couldn't update yt-dlp; carrying on with the installed version" >&2
fi
exec python3 server.py
