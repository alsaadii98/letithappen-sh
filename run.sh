#!/usr/bin/env bash
#
# terminal-song — big-font lyric visualizer for the terminal.
#
# Sync comes from mpv's own audio clock over the JSON IPC socket, so lyrics
# stay locked to the music through startup latency, pausing and seeking.
# Kept compatible with bash 3.2 (the /bin/bash that ships on macOS): no
# coproc, no associative arrays, no ${EPOCHREALTIME}.

set -uo pipefail

# ---------------------------------------------------------------------------
# Dependencies
#
# Offer to install what is missing instead of just failing. play.sh sources
# this file with TERMINAL_SONG_LIB=1 to reuse ensure_dependencies before it
# downloads the audio, so both entry points prompt identically.
#
# Note the prompt reads from /dev/tty, not stdin: under `curl … | bash` stdin
# is the pipe carrying the script, and reading it would eat the script.
# ---------------------------------------------------------------------------

package_installer() {
  if command -v brew    >/dev/null 2>&1; then echo "brew install";              return 0; fi
  if command -v apt-get >/dev/null 2>&1; then echo "sudo apt-get install -y";   return 0; fi
  if command -v dnf     >/dev/null 2>&1; then echo "sudo dnf install -y";       return 0; fi
  if command -v pacman  >/dev/null 2>&1; then echo "sudo pacman -S --noconfirm"; return 0; fi
  if command -v zypper  >/dev/null 2>&1; then echo "sudo zypper install -y";    return 0; fi
  if command -v apk     >/dev/null 2>&1; then echo "sudo apk add";              return 0; fi
  if command -v port    >/dev/null 2>&1; then echo "sudo port install";         return 0; fi
  return 1
}

ensure_dependencies() {
  local required="" optional="" wanted="" installer="" reply=""

  command -v mpv    >/dev/null 2>&1 || required="$required mpv"
  command -v perl   >/dev/null 2>&1 || required="$required perl"
  command -v ffmpeg >/dev/null 2>&1 || optional="$optional ffmpeg"

  if [[ -z "$required$optional" ]]; then
    return 0
  fi

  wanted="$required$optional"
  wanted="${wanted# }"

  echo
  if [[ -n "$required" ]]; then
    echo "Required, not installed:${required}"
  fi
  if [[ -n "$optional" ]]; then
    echo "Optional, not installed:${optional}  (spectrum bloom and bars)"
  fi

  installer="$(package_installer)" || installer=""

  if [[ -z "$installer" ]]; then
    echo
    echo "No supported package manager found. Install manually, then re-run:"
    echo "  macOS:         brew install $wanted"
    echo "  Debian/Ubuntu: sudo apt-get install $wanted"
    if [[ -n "$required" ]]; then
      return 1
    fi
    return 0
  fi

  # Non-interactive (cron, CI, no controlling terminal): never install
  # unattended, just say what to run. Test by opening /dev/tty rather than
  # with -r, which reports readable even where the open then fails.
  if ! { : < /dev/tty; } 2>/dev/null; then
    echo
    echo "Run: $installer $wanted"
    if [[ -n "$required" ]]; then
      return 1
    fi
    return 0
  fi

  echo
  echo "This will run:  $installer $wanted"
  printf 'Install now for the full experience? [y/N] '
  read -r reply < /dev/tty || reply=""
  echo

  case "$reply" in
    [yY] | [yY][eE][sS])
      # Intentionally unquoted: both parts carry multiple words.
      if ! $installer $wanted; then
        echo "Install failed. Run it yourself: $installer $wanted"
        if [[ -n "$required" ]]; then
          return 1
        fi
        return 0
      fi
      ;;
    *)
      if [[ -n "$required" ]]; then
        echo "Cannot run without:${required}"
        echo "Install with: $installer${required}"
        return 1
      fi
      echo "Continuing without:${optional}"
      return 0
      ;;
  esac

  if [[ -n "$required" ]]; then
    if ! command -v mpv >/dev/null 2>&1 || ! command -v perl >/dev/null 2>&1; then
      echo "Still missing after install. Check the output above."
      return 1
    fi
  fi
  return 0
}

# Sourced by play.sh purely for the helpers above.
if [[ "${TERMINAL_SONG_LIB:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

SONG_FILE="${1:-}"
LYRICS_FILE="${2:-}"

if [[ -z "$SONG_FILE" || -z "$LYRICS_FILE" ]]; then
  echo "Usage: $0 <song-file> <lyrics.lrc>"
  exit 1
fi

if [[ ! -f "$SONG_FILE" ]]; then
  echo "Song not found: $SONG_FILE"
  exit 1
fi

if [[ ! -f "$LYRICS_FILE" ]]; then
  echo "Lyrics not found: $LYRICS_FILE"
  exit 1
fi

if ! command -v mpv >/dev/null 2>&1; then
  echo "mpv is required."
  echo "macOS: brew install mpv"
  echo "Ubuntu: sudo apt install mpv"
  exit 1
fi

if ! command -v perl >/dev/null 2>&1; then
  echo "perl is required."
  exit 1
fi

RUNTIME_DIR="$(mktemp -d "${TMPDIR:-/tmp}/terminal-song.XXXXXX")"
MPV_SOCKET="$RUNTIME_DIR/mpv.sock"
CLOCK_IN="$RUNTIME_DIR/clock.in"
CLOCK_OUT="$RUNTIME_DIR/clock.out"
LINES_FILE="$RUNTIME_DIR/lines.tsv"
RENDER_FILE="$RUNTIME_DIR/render.awk"
CLOCK_HELPER="$RUNTIME_DIR/clock.pl"
KEYS_HELPER="$RUNTIME_DIR/keys.pl"
ART_FILE="$RUNTIME_DIR/art.txt"
SPECTRUM_FILE="$RUNTIME_DIR/spectrum.txt"
EFFECTS_FILE="$RUNTIME_DIR/effects.awk"
EFFECTS_IN="$RUNTIME_DIR/effects.in"
EFFECTS_OUT="$RUNTIME_DIR/effects.out"

cleanup() {
  printf '\033[0m\033[?25h\033[?1049l'

  if [[ -n "${CLOCK_PID:-}" ]]; then
    printf 'Q\n' >&7 2>/dev/null || true
    kill "$CLOCK_PID" 2>/dev/null || true
  fi
  if [[ -n "${KEY_PID:-}" ]]; then
    kill "$KEY_PID" 2>/dev/null || true
  fi
  if [[ -n "${PLAYER_PID:-}" ]]; then
    kill "$PLAYER_PID" 2>/dev/null || true
  fi
  if [[ -n "${SPECTRUM_PID:-}" ]]; then
    kill "$SPECTRUM_PID" 2>/dev/null || true
  fi
  if [[ -n "${EFFECTS_PID:-}" ]]; then
    kill "$EFFECTS_PID" 2>/dev/null || true
  fi
  if [[ -n "${TTY_STATE:-}" ]]; then
    stty "$TTY_STATE" < /dev/tty 2>/dev/null || true
  fi

  rm -rf "$RUNTIME_DIR" 2>/dev/null || true
}

trap cleanup EXIT
trap 'exit 0' INT TERM

# ---------------------------------------------------------------------------
# Lyrics
# ---------------------------------------------------------------------------

TRACK_TITLE="$(sed -n 's/^\[ti:[[:space:]]*\(.*\)\][[:space:]]*$/\1/p' "$LYRICS_FILE" | head -1)"
TRACK_ARTIST="$(sed -n 's/^\[ar:[[:space:]]*\(.*\)\][[:space:]]*$/\1/p' "$LYRICS_FILE" | head -1)"
[[ -z "$TRACK_TITLE" ]] && TRACK_TITLE="$(basename "$SONG_FILE")"

timestamps=()
lyrics=()

# Parse standard LRC timestamps such as [01:23.45]Some lyric, plus the
# enhanced-LRC per-word tags <01:23.45> which we strip for display.
while IFS=$'\t' read -r timestamp lyric; do
  timestamps+=("$timestamp")
  lyrics+=("$lyric")
done < <(
  awk '
    /^\[[0-9]+:[0-9]+(\.[0-9]+)?\]/ {
      close_bracket = index($0, "]")
      timestamp = substr($0, 2, close_bracket - 2)
      lyric = substr($0, close_bracket + 1)
      gsub(/<[0-9]+:[0-9]+(\.[0-9]+)?>/, "", lyric)

      colon = index(timestamp, ":")
      minutes = substr(timestamp, 1, colon - 1)
      seconds_fraction = substr(timestamp, colon + 1)
      dot = index(seconds_fraction, ".")

      if (dot == 0) {
        seconds = seconds_fraction
        fraction = 0
      } else {
        seconds = substr(seconds_fraction, 1, dot - 1)
        fraction = substr(seconds_fraction, dot + 1)
      }

      if (length(fraction) == 1) {
        fraction = fraction * 100
      } else if (length(fraction) == 2) {
        fraction = fraction * 10
      } else if (length(fraction) > 3) {
        fraction = substr(fraction, 1, 3)
      }

      total_ms = (minutes * 60 * 1000) + (seconds * 1000) + fraction

      printf "%d\t%s\n", total_ms, lyric
    }
  ' "$LYRICS_FILE" | sort -n
)

LYRIC_COUNT=${#timestamps[@]}

if (( LYRIC_COUNT == 0 )); then
  echo "No valid timestamped lyrics found."
  exit 1
fi

: > "$LINES_FILE"
for ((i = 0; i < LYRIC_COUNT; i++)); do
  printf '%d\t%s\n' "$i" "${lyrics[$i]}" >> "$LINES_FILE"
done

# ---------------------------------------------------------------------------
# Track length
# ---------------------------------------------------------------------------

DURATION_MS=0
if command -v ffprobe >/dev/null 2>&1; then
  duration_seconds="$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 "$SONG_FILE" 2>/dev/null || true)"
  if [[ "$duration_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    DURATION_MS="$(awk -v d="$duration_seconds" 'BEGIN { printf "%d", d * 1000 }')"
  fi
fi
if (( DURATION_MS <= 0 )); then
  DURATION_MS=$(( ${timestamps[$((LYRIC_COUNT - 1))]} + 15000 ))
fi

# ---------------------------------------------------------------------------
# Spectrum (precomputed once — no realtime DSP in the render loop)
#
# showspectrumpic renders the whole track as a single image: x is time,
# y is frequency. Read it back as raw grayscale and we have a lookup table
# of 16 band levels per time slice.
# ---------------------------------------------------------------------------

SPECTRUM_COLUMNS=0
SPEC=()

# Analysis takes a few seconds on a long track, so it runs alongside playback
# and the bars appear as soon as the table lands.
if command -v ffmpeg >/dev/null 2>&1; then
  spectrum_width=$(( DURATION_MS / 125 ))
  (( spectrum_width < 256 )) && spectrum_width=256
  (( spectrum_width > 4096 )) && spectrum_width=4096

  (
    ffmpeg -v error -nostdin -i "$SONG_FILE" \
      -lavfi "showspectrumpic=s=${spectrum_width}x16:legend=0:fscale=log:scale=sqrt:color=green" \
      -frames:v 1 -f rawvideo -pix_fmt gray - 2>/dev/null \
      | od -An -v -tu1 \
      | awk -v w="$spectrum_width" '
          {
            for (i = 1; i <= NF; i++) {
              row = int(index_counter / w)
              col = index_counter % w
              # row 0 is the highest frequency; store the low band first
              value[col, 15 - row] = $i
              index_counter++
            }
          }
          END {
            for (c = 0; c < w; c++) {
              out = value[c, 0]
              for (b = 1; b < 16; b++) out = out " " value[c, b]
              print out
            }
          }
        ' > "$SPECTRUM_FILE.partial" 2>/dev/null \
      && mv "$SPECTRUM_FILE.partial" "$SPECTRUM_FILE"
  ) &
  SPECTRUM_PID=$!
fi

load_spectrum() {
  local spectrum_row
  SPEC=()
  while IFS= read -r spectrum_row; do
    SPEC+=("$spectrum_row")
  done < "$SPECTRUM_FILE"
  SPECTRUM_COLUMNS=${#SPEC[@]}
}

# ---------------------------------------------------------------------------
# Helper processes
# ---------------------------------------------------------------------------

cat > "$CLOCK_HELPER" <<'PERL'
use strict;
use warnings;
use Time::HiRes qw(time sleep);
use IO::Socket::UNIX;

$| = 1;

my $sock_path = shift @ARGV;
my $sock;
my $request_id = 0;
my $base_audio = 0;
my $base_wall  = time();
my $paused     = 0;
my $last_sync  = 0;
my $connected  = 0;

sub socket_handle {
    return $sock if $sock;
    return undef unless -S $sock_path;
    $sock = IO::Socket::UNIX->new(Peer => $sock_path, Type => SOCK_STREAM());
    if ($sock) { $sock->autoflush(1); $connected = 1; }
    return $sock;
}

sub query {
    my ($property) = @_;
    my $handle = socket_handle() or return undef;
    $request_id++;
    my $sent = eval {
        print {$handle} qq({"command":["get_property","$property"],"request_id":$request_id}\n);
        1;
    };
    unless ($sent) { $sock = undef; return undef; }

    while (defined(my $line = <$handle>)) {
        next unless $line =~ /"request_id":$request_id\b/;
        return undef if $line =~ /"error":"(?!success)/;
        return ($1 eq 'true' ? 1 : 0) if $line =~ /"data":(true|false)/;
        return $1 + 0 if $line =~ /"data":(-?[0-9][0-9.eE+-]*)/;
        return undef;
    }
    $sock = undef;
    return undef;
}

sub resync {
    $last_sync = time();
    my $position = query('time-pos');
    return unless defined $position;
    my $pause_state = query('pause');
    $paused = (defined $pause_state && $pause_state) ? 1 : 0;
    $base_audio = $position;
    $base_wall  = time();
}

# Poll mpv a few times a second and interpolate in between, so the render
# loop gets a monotonic clock without an IPC round trip per frame.
sub now_ms {
    resync() if (time() - $last_sync) > 0.35;
    my $audio = $paused ? $base_audio : $base_audio + (time() - $base_wall);
    return int($audio * 1000 + 0.5);
}

while (my $command = <STDIN>) {
    chomp $command;
    if ($command =~ /^S([0-9]+)$/) {
        sleep($1 / 1000) if $1 > 0;
        print now_ms(), " ", $paused, "\n";
    } elsif ($command =~ /^U(-?[0-9]+)$/) {
        # Sleep until an absolute audio timestamp. Sleeping a fixed slice
        # instead would add the frame's own render time to every period.
        my $wait = ($1 - now_ms()) / 1000;
        $wait = 0.12 if $wait > 0.12;   # stay responsive while paused
        sleep($wait) if $wait > 0;
        print now_ms(), " ", $paused, "\n";
    } elsif ($command eq 'T') {
        print now_ms(), " ", $paused, "\n";
    } elsif ($command eq 'Q') {
        last;
    }
}
PERL

cat > "$KEYS_HELPER" <<'PERL'
use strict;
use warnings;
use IO::Select;
use IO::Socket::UNIX;

my ($parent_pid, $sock_path) = @ARGV;

open(my $tty, '<', '/dev/tty') or exit;
my $selector = IO::Select->new($tty);
my $sock;

sub mpv_command {
    my ($json) = @_;
    unless ($sock) {
        return unless -S $sock_path;
        $sock = IO::Socket::UNIX->new(Peer => $sock_path, Type => SOCK_STREAM());
        $sock->autoflush(1) if $sock;
    }
    return unless $sock;
    eval { print {$sock} "$json\n"; 1 } or $sock = undef;
}

sub quit { kill 'TERM', $parent_pid; exit; }

while (1) {
    my $key;
    sysread($tty, $key, 1) or last;

    if ($key eq "\e") {
        # Bare Escape quits; Escape followed by [ is an arrow key.
        unless ($selector->can_read(0.05)) { quit() }
        my $bracket;
        sysread($tty, $bracket, 1);
        next unless defined $bracket && $bracket eq '[';
        my $final;
        sysread($tty, $final, 1);
        next unless defined $final;
        mpv_command('{"command":["seek",5,"relative"]}')  if $final eq 'C';
        mpv_command('{"command":["seek",-5,"relative"]}') if $final eq 'D';
        next;
    }

    quit() if $key eq 'q' || $key eq 'Q';
    mpv_command('{"command":["cycle","pause"]}') if $key eq ' ';
}
PERL

# ---------------------------------------------------------------------------
# Glyph renderer
#
# Emits, for every lyric, a block of pre-rendered rows. Two font rows are
# packed into one terminal row with half-block characters, which doubles the
# vertical resolution and fixes the glyph aspect ratio. Each row is split into
# CHUNKS pieces by \001 so bash can colour it without ever slicing a UTF-8
# string.
# ---------------------------------------------------------------------------

cat > "$RENDER_FILE" <<'AWK'
function wrap(text, max_chars, out,   count, i, current, candidate, n, words) {
  count = split(text, words, /[ \t]+/)
  n = 0
  current = ""
  for (i = 1; i <= count; i++) {
    candidate = (current == "" ? words[i] : current " " words[i])
    if (length(candidate) > max_chars && current != "") {
      out[++n] = current
      current = words[i]
    } else {
      current = candidate
    }
  }
  if (current != "") out[++n] = current
  return n
}

function spaces(n,   s) { s = ""; while (n-- > 0) s = s "0"; return s }

BEGIN {
  FS = "\t"
  CHUNKS = 16

  f["A"]="01110/10001/11111/10001/10001"; f["B"]="11110/10001/11110/10001/11110"
  f["C"]="01111/10000/10000/10000/01111"; f["D"]="11110/10001/10001/10001/11110"
  f["E"]="11111/10000/11110/10000/11111"; f["F"]="11111/10000/11110/10000/10000"
  f["G"]="01111/10000/10111/10001/01111"; f["H"]="10001/10001/11111/10001/10001"
  f["I"]="11111/00100/00100/00100/11111"; f["J"]="00001/00001/00001/10001/01110"
  f["K"]="10001/10010/11100/10010/10001"; f["L"]="10000/10000/10000/10000/11111"
  f["M"]="10001/11011/10101/10001/10001"; f["N"]="10001/11001/10101/10011/10001"
  f["O"]="01110/10001/10001/10001/01110"; f["P"]="11110/10001/11110/10000/10000"
  f["Q"]="01110/10001/10101/10010/01101"; f["R"]="11110/10001/11110/10010/10001"
  f["S"]="01111/10000/01110/00001/11110"; f["T"]="11111/00100/00100/00100/00100"
  f["U"]="10001/10001/10001/10001/01110"; f["V"]="10001/10001/10001/01010/00100"
  f["W"]="10001/10001/10101/11011/10001"; f["X"]="10001/01010/00100/01010/10001"
  f["Y"]="10001/01010/00100/00100/00100"; f["Z"]="11111/00010/00100/01000/11111"
  f["0"]="01110/10011/10101/11001/01110"; f["1"]="00100/01100/00100/00100/01110"
  f["2"]="11110/00001/01110/10000/11111"; f["3"]="11110/00001/01110/00001/11110"
  f["4"]="10010/10010/11111/00010/00010"; f["5"]="11111/10000/11110/00001/11110"
  f["6"]="01111/10000/11110/10001/01110"; f["7"]="11111/00010/00100/01000/01000"
  f["8"]="01110/10001/01110/10001/01110"; f["9"]="01110/10001/01111/00001/11110"
  f["!"]="00100/00100/00100/00000/00100"; f["?"]="11110/00001/00110/00000/00100"
  f["."]="00000/00000/00000/00000/00100"; f[","]="00000/00000/00000/00100/01000"
  f["-"]="00000/00000/11111/00000/00000"; f["\047"]="00100/00100/01000/00000/00000"
  f["\""]="01010/01010/10100/00000/00000"; f[":"]="00000/00100/00000/00100/00000"
  f["("]="00010/00100/00100/00100/00010"; f[")"]="01000/00100/00100/00100/01000"
  f[" "]="00000/00000/00000/00000/00000"

  scale_count = split("8 6 5 4 3 2 1", scale_options, " ")
}

{
  index_id = $1
  text = $2
  gsub(/^[ \t]+|[ \t]+$/, "", text)

  if (text == "") {
    print "@" index_id " 0 0 0"
    next
  }

  plain_length = length(text)
  upper = toupper(text)

  # Pick the largest scale whose wrapped block still fits the art area.
  chosen = 0
  for (s = 1; s <= scale_count; s++) {
    scale = scale_options[s]
    max_chars = int((W - 2) / (6 * scale))
    if (max_chars < 1) continue
    line_count = wrap(upper, max_chars, lines)
    rows_per_line = int((5 * scale + 1) / 2)
    total_rows = line_count * rows_per_line + (line_count - 1)
    if (total_rows <= H) { chosen = scale; break }
  }
  if (chosen == 0) {
    chosen = 1
    max_chars = int((W - 2) / 6)
    if (max_chars < 1) max_chars = 1
    line_count = wrap(upper, max_chars, lines)
  }
  scale = chosen

  # Each glyph is 5 cells wide plus a 1 cell gap, all times the scale.
  # Vertical sub-rows repeat `scale` times too; the half-block packing then
  # halves that back down, giving a square-ish glyph.
  max_cols = 0
  for (l = 1; l <= line_count; l++) {
    cols = length(lines[l]) * 5 * scale + (length(lines[l]) - 1) * scale
    line_cols[l] = cols
    if (cols > max_cols) max_cols = cols
  }

  sub_count = 0
  for (l = 1; l <= line_count; l++) {
    left = int((max_cols - line_cols[l]) / 2)
    right = max_cols - line_cols[l] - left
    rendered = lines[l]
    for (row = 1; row <= 5; row++) {
      bits = spaces(left)
      for (i = 1; i <= length(rendered); i++) {
        ch = substr(rendered, i, 1)
        pattern = (ch in f ? f[ch] : "11111/10001/10101/10001/11111")
        split(pattern, pattern_rows, "/")
        for (col = 1; col <= 5; col++) {
          bit = substr(pattern_rows[row], col, 1)
          for (sx = 1; sx <= scale; sx++) bits = bits bit
        }
        if (i < length(rendered)) for (sx = 1; sx <= scale; sx++) bits = bits "0"
      }
      bits = bits spaces(right)
      for (sy = 1; sy <= scale; sy++) sub_rows[++sub_count] = bits
    }
    # Keep each logical line an even number of sub-rows so half-block pairing
    # never straddles two lines.
    if (sub_count % 2 == 1) sub_rows[++sub_count] = spaces(max_cols)
    if (l < line_count) {
      sub_rows[++sub_count] = spaces(max_cols)
      sub_rows[++sub_count] = spaces(max_cols)
    }
  }

  chunk_width = int((max_cols + CHUNKS - 1) / CHUNKS)
  if (chunk_width < 1) chunk_width = 1

  row_count = int((sub_count + 1) / 2)
  print "@" index_id " " max_cols " " plain_length " " row_count

  for (k = 1; k <= sub_count; k += 2) {
    upper_bits = sub_rows[k]
    lower_bits = (k + 1 <= sub_count) ? sub_rows[k + 1] : spaces(max_cols)
    out = ""
    for (c = 1; c <= max_cols; c++) {
      u = substr(upper_bits, c, 1)
      lo = substr(lower_bits, c, 1)
      if (u == "1" && lo == "1")      out = out "█"
      else if (u == "1")              out = out "▀"
      else if (lo == "1")             out = out "▄"
      else                            out = out " "
      if (c % chunk_width == 0 && c < max_cols) out = out "\001"
    }
    print out
  }

  delete sub_rows
  delete lines
  delete line_cols
}
AWK

# ---------------------------------------------------------------------------
# Visualizer
#
# A radial spectrum bloom: the 16 bands are wrapped around a circle (bass
# down, treble up, mirrored left/right), beats push rings outward, and a
# starfield fills the space between. Bash cannot do per-cell trigonometry at
# 20fps, so this runs as a persistent awk process over a FIFO pair — the same
# no-fork trick as the clock. Per-cell geometry is cached and only rebuilt
# when the terminal is resized.
# ---------------------------------------------------------------------------

cat > "$EFFECTS_FILE" <<'AWK'
function hue_escape(h, s, v,   c, seg, off, x, m, r, g, b, n, key) {
  h = h % 360
  if (h < 0) h += 360
  # Memoised across frames: the same few hundred (hue, level) pairs recur
  # every frame, and sprintf is one of the hottest calls here.
  key = int(h / 3) "," int(v * 100)
  if (key in COLOUR_CACHE) return COLOUR_CACHE[key]
  c = v * s
  seg = int(h / 60)
  off = (h / 60) - seg
  x = (seg % 2 == 0) ? c * off : c * (1 - off)
  m = v - c
  if (seg == 0)      { r = c; g = x; b = 0 }
  else if (seg == 1) { r = x; g = c; b = 0 }
  else if (seg == 2) { r = 0; g = c; b = x }
  else if (seg == 3) { r = 0; g = x; b = c }
  else if (seg == 4) { r = x; g = 0; b = c }
  else               { r = c; g = 0; b = x }
  r = int((r + m) * 255); g = int((g + m) * 255); b = int((b + m) * 255)
  # Quantise, so neighbouring cells share a colour and the run-length
  # encoding below actually collapses them into one escape.
  r = int(r / 12) * 12; g = int(g / 12) * 12; b = int(b / 12) * 12
  if (r > 255) r = 255
  if (g > 255) g = 255
  if (b > 255) b = 255
  if (TRUECOLOR) return COLOUR_CACHE[key] = sprintf("\033[38;2;%d;%d;%dm", r, g, b)
  n = 16 + 36 * int(r * 5 / 255) + 6 * int(g * 5 / 255) + int(b * 5 / 255)
  return COLOUR_CACHE[key] = sprintf("\033[38;5;%dm", n)
}

function noise(x, y,   v) {
  v = sin(x * 12.9898 + y * 78.233) * 43758.5453
  return v - int(v)
}

function build_geometry(   x, y, dx, dy, r, a, spoke, idx) {
  cx = (W - 1) / 2.0
  cy = (H - 1) / 2.0
  max_radius = W / 2.0
  if (max_radius < 1) max_radius = 1

  # Flat indices, not [x, y]: awk builds a "x SUBSEP y" string and hashes it
  # on every multidimensional access, and this loop does five per cell.
  for (y = 0; y < H; y++) {
    for (x = 0; x < W; x++) {
      idx = y * W + x
      dx = x - cx
      # Cells are about twice as tall as they are wide, so stretch y to make
      # a circle look like a circle.
      dy = (y - cy) * 1.85
      RR[idx] = sqrt(dx * dx + dy * dy) / max_radius
      a = atan2(dy, dx) / (2 * PI) + 0.5
      HB[idx] = a * 300
      # Mirror about the vertical axis, bass pointing down, treble up.
      spoke = a - 0.75
      if (spoke < -0.5) spoke += 1
      if (spoke < 0) spoke = -spoke
      BB[idx] = int(spoke * 2 * 15.999)
      PB[idx] = int(a * PETALS)
      NZ[idx] = noise(x + 1, y + 1)
    }
  }
  cached_w = W
  cached_h = H
}

BEGIN {
  PI = 3.14159265358979
  CHARS[0] = " "; CHARS[1] = "·"; CHARS[2] = "░"
  CHARS[3] = "▒"; CHARS[4] = "▓"; CHARS[5] = "█"
  RESET = "\033[0m"
  ring_count = 0
  last_t = -1
  PETALS = 180
}

{
  W = $1 + 0; H = $2 + 0; t = $3 + 0; bass = $4 / 255.0; beat = $5 + 0
  for (i = 0; i < 16; i++) {
    e = $(6 + i) / 255.0
    band[i] = e * e          # the sqrt-scaled source is far too flat raw
  }

  if (W != cached_w || H != cached_h) build_geometry()

  dt = (last_t < 0 || t < last_t) ? 0.05 : t - last_t
  if (dt > 0.5) dt = 0.5
  last_t = t

  for (i = 1; i <= ring_count; i++) ring_r[i] += dt * 0.75
  while (ring_count > 0 && ring_r[1] > 1.5) {
    for (i = 1; i < ring_count; i++) ring_r[i] = ring_r[i + 1]
    ring_count--
  }
  if (beat && ring_count < 6) ring_r[++ring_count] = 0.04

  core = 0.09 + 0.13 * bass
  spin = t * 30

  # sin() per cell was ~3800 calls a frame; the petal shape only varies with
  # angle, so evaluate it once per angular bucket instead.
  for (i = 0; i < PETALS; i++)
    petal_lut[i] = 0.78 + 0.22 * sin((i / PETALS) * 2 * PI * 5 + t * 1.7)

  for (y = 0; y < H; y++) {
    line = ""
    last_colour = ""
    row_base = y * W
    for (x = 0; x < W; x++) {
      idx = row_base + x
      r = RR[idx]; hb = HB[idx]; b = BB[idx]

      # Petals: modulate the bloom radius around the circle so the shape
      # breathes instead of sitting there as a disc.
      edge = core + 0.70 * band[b] * petal_lut[PB[idx]]

      level = 0
      hue = 0
      if (r < edge) {
        level = int((1 - r / edge) * 5.4) + 1
        if (level > 5) level = 5
        hue = hb + spin + r * 150
      } else if (r < edge + 0.045) {
        level = 1
        hue = hb + spin + 40
      }

      for (i = 1; i <= ring_count; i++) {
        d = r - ring_r[i]
        if (d < 0) d = -d
        if (d < 0.03) {
          rl = int((1 - ring_r[i] / 1.5) * 5) + 1
          if (rl > 5) rl = 5
          if (rl > level) { level = rl; hue = spin * 2.2 + ring_r[i] * 300 }
        }
      }

      if (level == 0) {
        n = NZ[idx]
        if (n > 0.9955 && sin(t * 2.5 + n * 100) > 0.1) {
          level = 1
          hue = 210 + n * 60
        }
      }

      if (level == 0) {
        if (last_colour != "") { line = line RESET; last_colour = "" }
        line = line " "
      } else {
        colour = hue_escape(hue, 0.72, 0.35 + 0.13 * level)
        if (colour != last_colour) { line = line colour; last_colour = colour }
        line = line CHARS[level]
      }
    }
    print line RESET
  }
  fflush()
}
AWK

# ---------------------------------------------------------------------------
# Terminal state
# ---------------------------------------------------------------------------

TERM_WIDTH=80
TERM_HEIGHT=24
RESIZE_PENDING=0

update_terminal_size() {
  local tty_size
  tty_size="$(stty size < /dev/tty 2>/dev/null || true)"
  if [[ "$tty_size" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
    TERM_HEIGHT=${tty_size%% *}
    TERM_WIDTH=${tty_size##* }
  else
    TERM_HEIGHT=24
    TERM_WIDTH=80
  fi
}

on_resize() { RESIZE_PENDING=1; }

update_terminal_size
trap on_resize WINCH

TTY_STATE="$(stty -g < /dev/tty 2>/dev/null || true)"
if [[ -n "$TTY_STATE" ]]; then
  stty -echo -icanon min 1 time 0 < /dev/tty
fi

# ---------------------------------------------------------------------------
# Colour
# ---------------------------------------------------------------------------

CHUNKS=16
HUE_STEPS=36
TRUECOLOR=0
if [[ "${COLORTERM:-}" == *truecolor* || "${COLORTERM:-}" == *24bit* ]]; then
  TRUECOLOR=1
fi

R=0; G=0; B=0
ESC_OUT=""

hsv_to_rgb() {
  local hue=$(( $1 % 360 )) saturation=$2 value=$3
  local chroma=$(( value * saturation * 255 / 10000 ))
  local segment=$(( hue / 60 ))
  local offset=$(( hue % 60 ))
  local x

  if (( segment % 2 == 0 )); then
    x=$(( chroma * offset / 60 ))
  else
    x=$(( chroma * (60 - offset) / 60 ))
  fi
  local minimum=$(( value * 255 / 100 - chroma ))

  case $segment in
    0) R=$chroma; G=$x;      B=0 ;;
    1) R=$x;      G=$chroma; B=0 ;;
    2) R=0;       G=$chroma; B=$x ;;
    3) R=0;       G=$x;      B=$chroma ;;
    4) R=$x;      G=0;       B=$chroma ;;
    *) R=$chroma; G=0;       B=$x ;;
  esac

  R=$(( R + minimum )); G=$(( G + minimum )); B=$(( B + minimum ))
}

set_escape() {
  if (( TRUECOLOR )); then
    printf -v ESC_OUT '\033[38;2;%d;%d;%dm' "$1" "$2" "$3"
  else
    printf -v ESC_OUT '\033[38;5;%dm' \
      $(( 16 + 36 * ($1 * 5 / 255) + 6 * ($2 * 5 / 255) + ($3 * 5 / 255) ))
  fi
}

PALETTE=()
PALETTE_BRIGHT=()

build_palette() {
  local hue index
  PALETTE=(); PALETTE_BRIGHT=()
  for ((hue = 0; hue < HUE_STEPS; hue++)); do
    for ((index = 0; index < CHUNKS; index++)); do
      hsv_to_rgb $(( hue * 10 + index * 6 )) 78 92
      set_escape "$R" "$G" "$B"
      PALETTE+=("$ESC_OUT")
      hsv_to_rgb $(( hue * 10 + index * 6 )) 26 100
      set_escape "$R" "$G" "$B"
      PALETTE_BRIGHT+=("$ESC_OUT")
    done
  done
}

build_palette

DIM=$'\033[2m'
RESET=$'\033[0m'
BOLD=$'\033[1m'

# ---------------------------------------------------------------------------
# Repeat tables — building strings by concatenation at startup keeps the frame
# loop free of both forks and UTF-8 slicing.
# ---------------------------------------------------------------------------

SPACES=()
BAR_FILL=()
BAR_EMPTY=()
BLOCK_RUNS=()
BAR_ROWS=0
BAND_COUNT=16
BLOCKS=(" " "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

build_tables() {
  local n level maximum_band
  SPACES=("")
  for ((n = 1; n <= TERM_WIDTH; n++)); do
    SPACES[$n]="${SPACES[$((n - 1))]} "
  done

  BAR_FILL=(""); BAR_EMPTY=("")
  for ((n = 1; n <= TERM_WIDTH; n++)); do
    BAR_FILL[$n]="${BAR_FILL[$((n - 1))]}━"
    BAR_EMPTY[$n]="${BAR_EMPTY[$((n - 1))]}─"
  done

  maximum_band=$(( TERM_WIDTH / BAND_COUNT + 2 ))
  BLOCK_RUNS=()
  for ((level = 0; level <= 8; level++)); do
    BLOCK_RUNS[$(( level * (maximum_band + 1) ))]=""
    for ((n = 1; n <= maximum_band; n++)); do
      BLOCK_RUNS[$(( level * (maximum_band + 1) + n ))]="${BLOCK_RUNS[$(( level * (maximum_band + 1) + n - 1 ))]}${BLOCKS[$level]}"
    done
  done
  BLOCK_STRIDE=$(( maximum_band + 1 ))

  if (( SPECTRUM_COLUMNS > 0 && TERM_HEIGHT >= 24 )); then
    BAR_ROWS=5
  elif (( SPECTRUM_COLUMNS > 0 && TERM_HEIGHT >= 18 )); then
    BAR_ROWS=3
  else
    BAR_ROWS=0
  fi
}

# ---------------------------------------------------------------------------
# Pre-rendered art
# ---------------------------------------------------------------------------

ART_OFFSET=()
ART_ROWS=()
ART_WIDTH=()
PLAIN_LENGTH=()
CHUNK_OFFSET=()
CHUNK_COUNT=()
CHUNK=()
CONTENT_HEIGHT=0
ART_AREA_HEIGHT=0

render_all_lyrics() {
  local art_width row_total chunk_total line header parts

  CONTENT_HEIGHT=$(( TERM_HEIGHT - BAR_ROWS - 3 ))
  (( CONTENT_HEIGHT < 5 )) && CONTENT_HEIGHT=5
  ART_AREA_HEIGHT=$(( CONTENT_HEIGHT - 4 ))
  (( ART_AREA_HEIGHT < 3 )) && ART_AREA_HEIGHT=3

  awk -v W="$TERM_WIDTH" -v H="$ART_AREA_HEIGHT" -f "$RENDER_FILE" \
    "$LINES_FILE" > "$ART_FILE"

  ART_OFFSET=(); ART_ROWS=(); ART_WIDTH=(); PLAIN_LENGTH=()
  CHUNK_OFFSET=(); CHUNK_COUNT=(); CHUNK=()
  row_total=0
  chunk_total=0

  while IFS= read -r line; do
    case "$line" in
      @*)
        header="${line#@}"
        set -- $header
        ART_OFFSET[$1]=$row_total
        ART_WIDTH[$1]=$2
        PLAIN_LENGTH[$1]=$3
        ART_ROWS[$1]=$4
        ;;
      *)
        parts=()
        local saved_ifs="$IFS"
        IFS=$'\001'
        parts=( $line )
        IFS="$saved_ifs"
        CHUNK_OFFSET[$row_total]=$chunk_total
        CHUNK_COUNT[$row_total]=${#parts[@]}
        local part
        for part in "${parts[@]}"; do
          CHUNK[$chunk_total]="$part"
          chunk_total=$(( chunk_total + 1 ))
        done
        row_total=$(( row_total + 1 ))
        ;;
    esac
  done < "$ART_FILE"
}

build_tables
render_all_lyrics

# ---------------------------------------------------------------------------
# Playback
# ---------------------------------------------------------------------------

printf '\033[?1049h\033[?25l'

MAIN_PID=$$

mpv \
  --no-video \
  --really-quiet \
  --no-terminal \
  --input-ipc-server="$MPV_SOCKET" \
  "$SONG_FILE" &
PLAYER_PID=$!

mkfifo "$CLOCK_IN" "$CLOCK_OUT"
perl "$CLOCK_HELPER" "$MPV_SOCKET" < "$CLOCK_IN" > "$CLOCK_OUT" &
CLOCK_PID=$!
exec 7> "$CLOCK_IN"
exec 8< "$CLOCK_OUT"

perl "$KEYS_HELPER" "$MAIN_PID" "$MPV_SOCKET" &
KEY_PID=$!

EFFECTS_OK=0
if mkfifo "$EFFECTS_IN" "$EFFECTS_OUT" 2>/dev/null; then
  awk -v TRUECOLOR="$TRUECOLOR" -f "$EFFECTS_FILE" \
    < "$EFFECTS_IN" > "$EFFECTS_OUT" &
  EFFECTS_PID=$!
  exec 3> "$EFFECTS_IN"
  exec 4< "$EFFECTS_OUT"
  EFFECTS_OK=1
fi

NOW_MS=0
PAUSED=0

# One write plus one read per frame; the sleep happens inside the helper so
# the render loop never forks.
clock_step() {
  local reply attempts=0
  printf '%s\n' "$1" >&7 2>/dev/null || return 1
  while (( attempts < 3 )); do
    if IFS=' ' read -r -u 8 NOW_MS PAUSED; then
      return 0
    fi
    attempts=$(( attempts + 1 ))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Frame composition
# ---------------------------------------------------------------------------

FRAME=""

emit_row() { # row, content
  FRAME+=$'\033['"$1"$';1H\033[K'"$2"
}

emit_centered() { # row, text, char length, colour
  local pad=$(( (TERM_WIDTH - $3) / 2 ))
  (( pad < 0 )) && pad=0
  (( pad > TERM_WIDTH )) && pad=$TERM_WIDTH
  emit_row "$1" "$4${SPACES[$pad]}$2$RESET"
}

format_time() { # milliseconds -> mm:ss
  local total=$(( $1 / 1000 ))
  (( total < 0 )) && total=0
  printf -v TIME_OUT '%d:%02d' $(( total / 60 )) $(( total % 60 ))
}

BASS=0
BASS_AVERAGE=0
BEAT=0
LAST_SPECTRUM_INDEX=-1
LAST_BEAT_MS=-10000
# Kept at a full 16 entries so the visualizer has something to read before the
# spectrum table finishes loading.
SPEC_VALUES=( 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 )

# Sampled once per frame before anything is drawn, so both the bars and the
# dancers react to the same beat.
sample_spectrum() {
  (( SPECTRUM_COLUMNS == 0 )) && { BEAT=0; return; }

  local spectrum_index=$(( NOW_MS * SPECTRUM_COLUMNS / DURATION_MS ))
  (( spectrum_index < 0 )) && spectrum_index=0
  (( spectrum_index >= SPECTRUM_COLUMNS )) && spectrum_index=$(( SPECTRUM_COLUMNS - 1 ))

  # A spectrum column lasts longer than a frame. Re-deciding every frame would
  # feed the running average the same value repeatedly and flatten it, so hold
  # the verdict until the column actually advances.
  if (( spectrum_index == LAST_SPECTRUM_INDEX )); then
    return
  fi
  LAST_SPECTRUM_INDEX=$spectrum_index
  BEAT=0

  set -- ${SPEC[$spectrum_index]}
  SPEC_VALUES=( "$@" )
  BASS=$(( (${SPEC_VALUES[0]:-0} + ${SPEC_VALUES[1]:-0}) / 2 ))

  # A kick is bass well above its own running average, not just bass that is
  # loud — otherwise a dense mix reads as one continuous beat. The refractory
  # gap then forces the crew back down between hops; without it a loud passage
  # latches the hop on and the dancers simply sit one row higher.
  if (( BASS > 70 )) && (( BASS * 100 > BASS_AVERAGE * 118 )) \
     && (( NOW_MS - LAST_BEAT_MS > 220 )); then
    BEAT=1
    LAST_BEAT_MS=$NOW_MS
  fi
  BASS_AVERAGE=$(( (BASS_AVERAGE * 7 + BASS) / 8 ))
}

emit_spectrum() { # top row
  local top=$1 row band level height eighths run column_width remainder
  local line palette_index

  (( BAR_ROWS == 0 )) && return

  local values=( "${SPEC_VALUES[@]}" )

  column_width=$(( TERM_WIDTH / BAND_COUNT ))
  (( column_width < 1 )) && column_width=1
  remainder=$(( TERM_WIDTH - column_width * BAND_COUNT ))

  local hue_base=$(( (NOW_MS / 400) % HUE_STEPS ))
  for ((row = 0; row < BAR_ROWS; row++)); do
    line=""
    for ((band = 0; band < BAND_COUNT; band++)); do
      level=${values[$band]:-0}
      # Square the level: showspectrumpic's sqrt scale already lifts the floor,
      # so without this every band pins to the top and the bars stop moving.
      eighths=$(( level * level * BAR_ROWS * 8 / 65025 ))
      height=$(( eighths - (BAR_ROWS - 1 - row) * 8 ))
      (( height < 0 )) && height=0
      (( height > 8 )) && height=8
      run=$column_width
      (( band < remainder )) && run=$(( run + 1 ))
      palette_index=$(( hue_base * CHUNKS + band ))
      line+="${PALETTE[$palette_index]}${BLOCK_RUNS[$(( height * BLOCK_STRIDE + run ))]}"
    done
    emit_row $(( top + row )) "$line$RESET"
  done
}

emit_footer() {
  local progress_row=$(( TERM_HEIGHT - 2 ))
  local status_row=$(( TERM_HEIGHT - 1 ))
  local width=$(( TERM_WIDTH - 2 ))
  (( width < 1 )) && width=1

  local filled=$(( NOW_MS * width / DURATION_MS ))
  (( filled < 0 )) && filled=0
  (( filled > width )) && filled=$width

  local hue_base=$(( (NOW_MS / 400) % HUE_STEPS ))
  emit_row "$progress_row" \
    " ${PALETTE[$(( hue_base * CHUNKS ))]}${BAR_FILL[$filled]}$DIM${BAR_EMPTY[$(( width - filled ))]}$RESET"

  format_time "$NOW_MS"; local elapsed="$TIME_OUT"
  format_time "$DURATION_MS"; local total="$TIME_OUT"

  local marker="♪"
  (( PAUSED )) && marker="⏸"

  local status="$marker  $TRACK_TITLE"
  [[ -n "$TRACK_ARTIST" ]] && status+=" — $TRACK_ARTIST"
  status+="   $elapsed / $total"
  emit_centered "$status_row" "$status" "${#status}" "$DIM"

  local help="Space: pause  •  ←/→: seek 5s  •  Esc/Q: exit  •  © @alsaadii98"
  emit_centered "$TERM_HEIGHT" "$help" "${#help}" "$DIM"
}

emit_art() { # lyric index, reveal chunks, sweep chunk, hue base
  local lyric=$1 reveal=$2 sweep=$3 hue_base=$4
  local rows=${ART_ROWS[$lyric]:-0}
  (( rows == 0 )) && return 1

  local width=${ART_WIDTH[$lyric]:-0}
  local pad=$(( (TERM_WIDTH - width) / 2 ))
  (( pad < 0 )) && pad=0
  (( pad > TERM_WIDTH )) && pad=$TERM_WIDTH

  local top=$(( 1 + (CONTENT_HEIGHT - rows) / 2 ))
  (( top < 1 )) && top=1

  local row offset count chunk_index line palette_index
  for ((row = 0; row < rows; row++)); do
    offset=${CHUNK_OFFSET[$(( ART_OFFSET[lyric] + row ))]}
    count=${CHUNK_COUNT[$(( ART_OFFSET[lyric] + row ))]}
    line="${SPACES[$pad]}"
    for ((chunk_index = 0; chunk_index < count; chunk_index++)); do
      (( chunk_index > reveal )) && break
      palette_index=$(( hue_base * CHUNKS + chunk_index ))
      if (( BEAT )) || (( chunk_index == sweep )); then
        line+="${PALETTE_BRIGHT[$palette_index]}"
      else
        line+="${PALETTE[$palette_index]}"
      fi
      line+="${CHUNK[$(( offset + chunk_index ))]}"
    done
    emit_row $(( top + row )) "$line$RESET"
  done

  ART_TOP=$top
  ART_BOTTOM=$(( top + rows - 1 ))
  return 0
}

emit_neighbours() { # previous index, next index
  local previous=$1 next=$2
  if (( previous >= 0 )) && (( ${PLAIN_LENGTH[$previous]:-0} > 0 )) \
     && (( ART_TOP - 2 >= 1 )); then
    emit_centered $(( ART_TOP - 2 )) "${lyrics[$previous]}" \
      "${PLAIN_LENGTH[$previous]}" "$DIM"
  fi
  if (( next < LYRIC_COUNT )) && (( ${PLAIN_LENGTH[$next]:-0} > 0 )) \
     && (( ART_BOTTOM + 2 <= CONTENT_HEIGHT )); then
    emit_centered $(( ART_BOTTOM + 2 )) "${lyrics[$next]}" \
      "${PLAIN_LENGTH[$next]}" "$DIM"
  fi
}

# Fills rows 1..CONTENT_HEIGHT. Lyric rows are drawn afterwards and erase
# their own line, so the bloom shows through above and below the text.
emit_visualizer() {
  local row line

  (( EFFECTS_OK == 0 )) && return 1

  printf '%d %d %d.%03d %d %d %s\n' \
    "$TERM_WIDTH" "$CONTENT_HEIGHT" \
    $(( NOW_MS / 1000 )) $(( NOW_MS % 1000 )) \
    "$BASS" "$BEAT" "${SPEC_VALUES[*]}" >&3 2>/dev/null || {
      EFFECTS_OK=0
      return 1
    }

  for ((row = 1; row <= CONTENT_HEIGHT; row++)); do
    if ! IFS= read -r -u 4 line; then
      EFFECTS_OK=0
      return 1
    fi
    FRAME+=$'\033['"$row"$';1H\033[K'"$line"
  done
  return 0
}

clear_region() { # first row, last row
  local row
  for ((row = $1; row <= $2; row++)); do
    FRAME+=$'\033['"$row"$';1H\033[K'
  done
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

printf '\033[H\033[J'

FRAME_MS=50
frame_counter=0
current_index=-1
ART_TOP=1
ART_BOTTOM=1
TIME_OUT=""

clock_step "T" || true
FRAME_DEADLINE=$(( NOW_MS + FRAME_MS ))

while true; do
  if ! kill -0 "$PLAYER_PID" 2>/dev/null; then
    break
  fi

  if (( SPECTRUM_COLUMNS == 0 )) && (( frame_counter % 20 == 0 )) \
     && [[ -f "$SPECTRUM_FILE" ]]; then
    load_spectrum
    (( SPECTRUM_COLUMNS > 0 )) && RESIZE_PENDING=1
  fi

  if (( RESIZE_PENDING )); then
    RESIZE_PENDING=0
    update_terminal_size
    build_tables
    build_palette
    render_all_lyrics
    printf '\033[H\033[J'
  fi

  # Locate the active lyric. Rescanning on a backwards jump keeps seeking
  # correct without any extra bookkeeping.
  if (( current_index >= 0 )) && (( NOW_MS < timestamps[current_index] )); then
    current_index=-1
  fi
  while (( current_index + 1 < LYRIC_COUNT )) \
     && (( NOW_MS >= timestamps[current_index + 1] )); do
    current_index=$(( current_index + 1 ))
  done

  sample_spectrum

  FRAME=""

  if (( current_index < 0 )); then
    line_start=0
    line_end=${timestamps[0]}
    show_art=0
  else
    line_start=${timestamps[$current_index]}
    if (( current_index + 1 < LYRIC_COUNT )); then
      line_end=${timestamps[$((current_index + 1))]}
    else
      line_end=$DURATION_MS
    fi
    show_art=1
    (( ${ART_ROWS[$current_index]:-0} == 0 )) && show_art=0
  fi

  line_duration=$(( line_end - line_start ))
  (( line_duration < 1 )) && line_duration=1
  elapsed_in_line=$(( NOW_MS - line_start ))
  (( elapsed_in_line < 0 )) && elapsed_in_line=0

  hue=$(( ((current_index + 1) * 7 + NOW_MS / 900) % HUE_STEPS ))

  if (( show_art )); then
    reveal_ms=$(( line_duration / 4 ))
    (( reveal_ms > 320 )) && reveal_ms=320
    (( reveal_ms < 80 )) && reveal_ms=80
    if (( elapsed_in_line >= reveal_ms )); then
      reveal=$CHUNKS
    else
      reveal=$(( elapsed_in_line * CHUNKS / reveal_ms ))
    fi

    sweep=$(( elapsed_in_line * CHUNKS / line_duration ))
    (( sweep >= CHUNKS )) && sweep=-1

    emit_visualizer || clear_region 1 "$CONTENT_HEIGHT"
    if emit_art "$current_index" "$reveal" "$sweep" "$hue"; then
      emit_neighbours $(( current_index - 1 )) $(( current_index + 1 ))
    fi
  else
    emit_visualizer || clear_region 1 "$CONTENT_HEIGHT"
    if (( current_index < 0 )); then
      intro="$TRACK_TITLE"
      [[ -n "$TRACK_ARTIST" ]] && intro+=" — $TRACK_ARTIST"
      emit_centered 1 "$intro" "${#intro}" "$BOLD"
    fi
  fi

  if (( BAR_ROWS > 0 )); then
    emit_spectrum $(( CONTENT_HEIGHT + 1 ))
  fi
  emit_footer

  printf '%s' "$FRAME"

  frame_counter=$(( frame_counter + 1 ))

  if (( NOW_MS >= DURATION_MS )); then
    break
  fi

  # Advance the deadline rather than sleeping a fixed slice, so render time is
  # absorbed by the wait instead of being added to it. If we fall far behind
  # (a pause, a resize, a slow frame) the deadline resets instead of the loop
  # trying to catch up by racing through frames.
  FRAME_DEADLINE=$(( FRAME_DEADLINE + FRAME_MS ))
  if (( FRAME_DEADLINE < NOW_MS )) || (( FRAME_DEADLINE - NOW_MS > 500 )); then
    FRAME_DEADLINE=$(( NOW_MS + FRAME_MS ))
  fi

  clock_step "U$FRAME_DEADLINE" || break
done

wait "$PLAYER_PID" 2>/dev/null || true
