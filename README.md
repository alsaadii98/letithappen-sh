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

## Files

| File | Purpose |
| --- | --- |
| `run.sh` | Terminal player and lyric renderer |
| `play.sh` | Remote download-and-play launcher |
| `1.lrc` | Timestamped lyrics |
| `1.mp3` | Audio file |

## Free hosting

GitHub can serve these files directly from a public repository. After changing
files:

```bash
git add README.md play.sh run.sh 1.mp3 1.lrc
git commit -m "docs: add project readme"
git push origin main
```

Remote launcher URL:

```text
https://raw.githubusercontent.com/alsaadii98/letithappen-sh/main/play.sh
```

## Credits

- Project: [@alsaadii98](https://github.com/alsaadii98)
- Dancer artwork: PN,
  [ASCII Art Archive](https://asciiart.website/art/4020)

## Music rights

Only publish audio and lyrics you own or have permission to distribute.
Project attribution does not grant rights to third-party music or lyrics.
