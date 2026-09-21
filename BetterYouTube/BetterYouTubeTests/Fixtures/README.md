Synthetic, one-second test media; no third-party footage or audio.

Regenerate with FFmpeg on a development machine (FFmpeg is not an app dependency):

```sh
ffmpeg -f lavfi -i 'color=c=blue:s=160x90:r=10:d=1' -an -c:v libx264 -pix_fmt yuv420p video.mp4
ffmpeg -f lavfi -i 'sine=frequency=440:duration=1' -vn -c:a aac audio.m4a
```
