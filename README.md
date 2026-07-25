# Let It Happen — Terminal Song

Play synchronized LRC lyrics as animated terminal art. Includes responsive
block lettering, instrumental ASCII animation, and keyboard controls.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/alsaadii98/letithappen-sh/main/play.sh | bash
```

This downloads temporary copies of the runner, audio, and lyrics. Temporary
files are removed after playback.

> Running remote shell scripts carries risk. Review
> [`play.sh`](./play.sh) before piping it into Bash.

## Requirements

- Bash
- `curl`
- [`mpv`](https://mpv.io/)
- Perl

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
| `Q` | Exit |
| `Esc` | Exit |
| `Ctrl+C` | Exit |


