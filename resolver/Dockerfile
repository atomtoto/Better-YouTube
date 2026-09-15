FROM python:3.12-slim

# ffmpeg is what joins video and audio for anything above ~360p, where YouTube stops offering a
# single combined stream. Without it the resolver still works, but only at the qualities that
# come already joined — it says so plainly rather than failing oddly.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir yt-dlp

WORKDIR /app
COPY server.py entrypoint.sh ./
RUN chmod +x entrypoint.sh && useradd --create-home --uid 10001 resolver
USER resolver

ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s \
    CMD python3 -c "import urllib.request,os;urllib.request.urlopen(f\"http://127.0.0.1:{os.environ.get('PORT','8080')}/health\").read()"

ENTRYPOINT ["./entrypoint.sh"]
