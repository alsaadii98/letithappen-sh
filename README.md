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
curl -fsSL https://letithappen.alsaadii98.com/play.sh | bash
```

This downloads temporary copies of the runner, audio, and lyrics into a temp
directory that is removed when playback ends.

If `mpv`, `perl` or `ffmpeg` is missing, the script says so and offers to
install it with whatever package manager it finds (`brew`, `apt-get`, `dnf`,
`pacman`, `zypper`, `apk`, `port`). It always shows the exact command first
and defaults to no — nothing is installed unless you say yes. With no
controlling terminal it never prompts, it just prints the command. The check
runs before the audio downloads, so a missing `mpv` fails in a second rather
than after 11MB.

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

The one-liner offers to install these for you. To do it yourself:

```bash
# macOS
brew install mpv ffmpeg

# Ubuntu/Debian
sudo apt install mpv ffmpeg
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

## How it works

| Piece | Approach |
| --- | --- |
| Timing | mpv's `time-pos` over a JSON IPC socket, polled a few times a second and interpolated between — survives startup latency, pause and seek |
| Lettering | 5x5 bitmap font, two rows packed per terminal row as half-blocks, split into 16 chunks for the gradient and the reveal wipe |
| Spectrum | `showspectrumpic` renders the whole track as one image at startup; the render loop just indexes it by timestamp |
| Bloom | a persistent `awk` process draws each frame over a FIFO, so no process is forked per frame |
| Scheduling | frames sleep to an absolute audio deadline, so render time is absorbed by the wait instead of added to it |

Everything stays within bash 3.2 — no `coproc`, no associative arrays, no
`$EPOCHREALTIME` — because `/bin/bash` on macOS is still 3.2 and that is what
the one-liner runs.

## The page

[letithappen.alsaadii98.com](https://letithappen.alsaadii98.com) is served from
this repository by GitHub Pages. Its wordmark uses the same bitmap font as the
player and its background is the same bloom, ported to canvas and driven by a
synthetic beat instead of an ffmpeg analysis.
