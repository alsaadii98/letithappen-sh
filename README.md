# Let It Happen — Terminal Song

Play synchronized LRC lyrics as animated terminal art: half-block big
lettering with a truecolor gradient over a live radial spectrum bloom, an
audio-reactive bar spectrum, and a three-line lyric stack.

The bloom wraps the track's 16 frequency bands around a circle — bass pointing
down, treble up, mirrored left to right — so its shape is the music. Kick
drums push rings outward and flare the lettering. It is generated per frame by
a persistent `awk` process rather than being fixed ASCII art.

Timing comes from mpv's own audio clock over its JSON IPC socket, so the
lyrics stay locked to the music through startup latency, pausing and seeking.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/alsaadii98/letithappen-sh/main/play.sh | bash
```

This downloads temporary copies of the runner, audio, and lyrics. Temporary
files are removed after playback.

> Running remote shell scripts carries risk. Review
> [`play.sh`](./play.sh) before piping it into Bash.

## Requirements

- Bash (3.2 or newer — the `/bin/bash` shipped with macOS works)
- `curl`
- [`mpv`](https://mpv.io/)
- Perl
- `ffmpeg` (optional — drives the bloom and the bars; analysis runs in the
  background while playback starts, so there is no wait before the music)

Without `ffmpeg` everything still runs; the visuals just fall back to a
starfield with no spectrum reacting behind them.

Install `mpv`:

```bash
# macOS
brew install mpv

# Ubuntu/Debian
sudo apt install mpv
```

## Run locally

Clone the repository:

```bash
git clone https://github.com/alsaadii98/letithappen-sh.git
cd letithappen-sh
./run.sh 1.mp3 1.lrc
```

Run another song:

```bash
./run.sh path/to/song.mp3 path/to/lyrics.lrc
```

LRC lines must contain timestamps:

```text
[00:12.34]First lyric line
[00:18.90]Next lyric line
```

## Controls

| Key | Action |
| --- | --- |
| `Space` | Pause / resume |
| `←` / `→` | Seek 5 seconds |
| `Q` | Exit |
| `Esc` | Exit |
| `Ctrl+C` | Exit |

Enhanced-LRC per-word tags (`<00:12.34>`) are accepted and stripped for
display. Truecolor is used when `$COLORTERM` advertises it, with a 256-color
fallback.


