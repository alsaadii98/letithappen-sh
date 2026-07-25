#!/usr/bin/env bash

set -euo pipefail

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

timestamps=()
lyrics=()

# Parse standard LRC timestamps such as:
# [01:23.45]Some lyric
while IFS=$'\t' read -r timestamp lyric; do
  timestamps+=("$timestamp")
  lyrics+=("$lyric")
done < <(
  awk '
    /^\[[0-9]+:[0-9]+(\.[0-9]+)?\]/ {
      close_bracket = index($0, "]")
      timestamp = substr($0, 2, close_bracket - 2)
      lyric = substr($0, close_bracket + 1)

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

if [[ ${#timestamps[@]} -eq 0 ]]; then
  echo "No valid timestamped lyrics found."
  exit 1
fi

cleanup() {
  printf '\033[?25h' # Show cursor
  printf '\033[0m'
  printf '\033[?1049l' # Leave alternate screen

  if [[ -n "${PLAYER_PID:-}" ]]; then
    kill "$PLAYER_PID" 2>/dev/null || true
  fi

  if [[ -n "${KEY_PID:-}" ]]; then
    kill "$KEY_PID" 2>/dev/null || true
  fi

  if [[ -n "${TTY_STATE:-}" ]]; then
    stty "$TTY_STATE" < /dev/tty 2>/dev/null || true
  fi

}

trap cleanup EXIT
trap 'exit 0' INT TERM

get_time_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

sleep_ms() {
  local milliseconds="$1"
  local slice

  while (( milliseconds > 0 )); do
    slice=$milliseconds
    (( slice > 75 )) && slice=75
    perl -MTime::HiRes=sleep -e "sleep($slice / 1000)"
    milliseconds=$((milliseconds - slice))
  done
}

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

terminal_width() {
  echo "$TERM_WIDTH"
}

terminal_height() {
  echo "$TERM_HEIGHT"
}

center_text() {
  local text="$1"
  local width
  local padding

  width="$(terminal_width)"
  padding=$(( (width - ${#text}) / 2 ))

  if (( padding < 0 )); then
    padding=0
  fi

  printf "%*s%s" "$padding" "" "$text"
}

draw_footer() {
  local status="$1"
  local height

  height="$(terminal_height)"
  printf '\033[%d;1H\033[2K\033[2m' "$((height - 1))"
  center_text "$status"
  printf '\033[0m\033[%d;1H\033[2K\033[2m' "$height"
  center_text "© @alsaadii98 on GitHub  •  Esc/Q: Exit"
  printf '\033[0m'
}

draw_screen() {
  local current="$1"
  local status="${2:-♪ Playing}"
  local height
  local middle

  height="$(terminal_height)"
  middle=$((height / 2))
  printf '\033[H\033[J'
  printf '\033[%d;1H\033[2K\033[1;36m' "$middle"
  center_text "$current"
  printf '\033[0m'
  draw_footer "$status  •  Press Ctrl+C to stop"
}

render_word() {
  local word="$1"
  local width
  local height
  local scale
  local candidate_scale
  local max_chars
  local estimated_rows
  local estimated_height
  local line_gap
  local art_line

  width="$(terminal_width)"
  height="$(terminal_height)"
  scale=1

  for candidate_scale in 3 2 1; do
    max_chars=$(((width - 4) / (6 * candidate_scale)))
    (( max_chars < 1 )) && max_chars=1
    estimated_rows=$(((${#word} + max_chars - 1) / max_chars))
    estimated_height=$((estimated_rows * 5 * candidate_scale))

    if (( estimated_height <= height - 4 )); then
      scale=$candidate_scale
      break
    fi
  done

  max_chars=$(((width - 4) / (6 * scale)))
  (( max_chars < 1 )) && max_chars=1
  estimated_rows=$(((${#word} + max_chars - 1) / max_chars))
  line_gap=1
  if (( estimated_rows * 5 * scale + estimated_rows - 1 > height - 4 )); then
    line_gap=0
  fi

  ART_LINES=()
  ART_WIDTH=0
  while IFS= read -r art_line; do
    art_line="${art_line%"${art_line##*[![:space:]]}"}"
    ART_LINES+=("$art_line")
    if (( ${#art_line} > ART_WIDTH )); then
      ART_WIDTH=${#art_line}
    fi
  done < <(
    awk -v text="$word" -v scale="$scale" -v max_chars="$max_chars" \
      -v line_gap="$line_gap" '
      BEGIN {
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
        f["\""]="01010/01010/10100/00000/00000"
        f[" "]="00000/00000/00000/00000/00000"

        text=toupper(text)
        count=split(text, words, /[[:space:]]+/)
        line_count=0
        current=""
        for (w=1; w<=count; w++) {
          candidate=(current=="" ? words[w] : current " " words[w])
          if (length(candidate)>max_chars && current!="") {
            lines[++line_count]=current
            current=words[w]
          } else {
            current=candidate
          }
        }
        if (current!="") lines[++line_count]=current

        for (logical=1; logical<=line_count; logical++) {
          rendered=lines[logical]
          for (row=1; row<=5; row++) {
            line=""
            for (i=1; i<=length(rendered); i++) {
              ch=substr(rendered,i,1)
              pattern=(ch in f ? f[ch] : "11111/10001/10101/10001/11111")
              split(pattern, rows, "/")
              for (col=1; col<=5; col++) {
                pixel=(substr(rows[row],col,1)=="1" ? "█" : " ")
                for (sx=1; sx<=scale; sx++) line=line pixel
              }
              if (i<length(rendered)) {
                for (sx=1; sx<=scale; sx++) line=line " "
              }
            }
            for (sy=1; sy<=scale; sy++) print line
          }
          if (logical<line_count && line_gap==1) print ""
        }
      }
    '
  )
  ART_HEIGHT=${#ART_LINES[@]}
}

draw_art_screen() {
  local offset="$1"
  local status="$2"
  local width
  local art_line
  local visible
  local start
  local height
  local top_padding
  local screen_row
  local rendered_line
  local frame_buffer=""

  width="$(terminal_width)"
  height="$(terminal_height)"
  top_padding=$(((height - ART_HEIGHT - 2) / 2))
  (( top_padding < 0 )) && top_padding=0

  screen_row=$((top_padding + 1))
  for art_line in "${ART_LINES[@]}"; do
    visible="$art_line"
    if (( offset < 0 )); then
      start=$((-offset))
      if (( start >= ${#visible} )); then
        visible=""
      else
        visible="${visible:start}"
      fi
      rendered_line="${visible:0:width}"
    else
      printf -v rendered_line '%*s%s' "$offset" "" \
        "${visible:0:$((width - offset))}"
    fi

    printf -v rendered_line '%-*s' "$width" "$rendered_line"
    frame_buffer+=$'\033['"$screen_row"$';1H'"$rendered_line"
    screen_row=$((screen_row + 1))
  done

  printf '\033[1;36m%s\033[0m' "$frame_buffer"
}

draw_dancer() {
  local frame="$1"
  local height
  local top
  local width
  local line
  local dancer_width=0
  local padding
  local shift
  local frame_index
  local row_step
  local row
  local frame_buffer=""
  local dancer_lines=(
    "   _                             .-."
    "  / )  .-.    ___          __   (   )"
    " ( (  (   ) .'___)        (__'-._) ("
    "  \\ '._) (,'.'               '.     '-."
    "   '.      /  \"\\               '    -. '."
    "     )    /   \\ \\   .-.   ,'.   )  (  ',_)    _"
    "   .'    (     \\ \\ (   \\ . .' .'    )    .-. ( \\"
    "  (  .''. '.    \\ \\|  .' .' ,',--, /    (   ) ) )"
    "   \\ \\   ', :    \\    .-'  ( (  ( (     _) (,' /"
    "    \\ \\   : :    )  / _     ' .  \\ \\  ,'      /"
    "  ,' ,'   : ;   /  /,' '.   /.'  / / ( (\\    ("
    "  '.'      \"   (    .-'. \\       ''   \\_)\\    \\"
    "                \\  |    \\ \\__             )    )"
    "              ___\\ |     \\___;           /  , /"
    "             /  ___)                    (  ( ("
    "            '.'                         ) ;) ;"
    "                                        (*/(*/"
  )

  height="$(terminal_height)"
  width="$(terminal_width)"
  row_step=$(((${#dancer_lines[@]} + height - 4) / (height - 3)))
  (( row_step < 1 )) && row_step=1
  top=$(((height - ((${#dancer_lines[@]} + row_step - 1) / row_step) - 2) / 2))
  (( top < 1 )) && top=1

  for line in "${dancer_lines[@]}"; do
    (( ${#line} > dancer_width )) && dancer_width=${#line}
  done
  padding=$(((width - dancer_width) / 2))
  (( padding < 0 )) && padding=0
  frame_index=$((frame % 8))

  for ((row = 0; row < ${#dancer_lines[@]}; row += row_step)); do
    line="${dancer_lines[$row]}"

    if (( row <= 4 )); then
      case "$frame_index" in
        1|2) shift=-1 ;;
        5|6) shift=1 ;;
        *) shift=0 ;;
      esac
    elif (( row <= 11 )); then
      case "$frame_index" in
        2|3) shift=-1 ;;
        6|7) shift=1 ;;
        *) shift=0 ;;
      esac
    else
      case "$frame_index" in
        1|4) shift=1 ;;
        3|6) shift=-1 ;;
        *) shift=0 ;;
      esac
    fi

    if (( shift > 0 )); then
      line=" $line"
    elif (( shift < 0 )); then
      line="${line:1}"
    fi

    printf -v line '%*s%s' "$padding" "" "$line"
    line="${line:0:width}"
    printf -v line '%-*s' "$width" "$line"
    frame_buffer+=$'\033['"$top"$';1H'"$line"
    top=$((top + 1))
  done

  printf '\033[1;36m%s\033[0m' "$frame_buffer"
}

animate_instrumental() {
  local lyric_end_ms="$1"
  local frame=0
  local remaining_ms
  local delay_ms

  printf '\033[H\033[J'
  draw_footer "♫ Instrumental  •  Dancer: PN / asciiart.website/art/4020"
  while true; do
    remaining_ms=$(((START_TIME + lyric_end_ms) - $(get_time_ms)))
    if (( remaining_ms <= 0 )); then
      break
    fi

    draw_dancer "$frame"
    frame=$((frame + 1))
    delay_ms=75
    if (( remaining_ms < delay_ms )); then
      delay_ms=$remaining_ms
    fi
    sleep_ms "$delay_ms"
  done
}

animate_line() {
  local current="$1"
  local duration_ms="$2"
  local lyric_end_ms="$3"
  local width
  local target_offset
  local start_offset
  local travel
  local frame_ms
  local frame_count
  local frame
  local offset
  local animation_ms
  local remaining_ms

  if [[ -z "$current" ]]; then
    animate_instrumental "$lyric_end_ms"
    return
  fi

  render_word "$current"
  printf '\033[H\033[J'
  draw_footer "♪ Playing  •  Press Ctrl+C to stop"
  width="$(terminal_width)"
  target_offset=$(((width - ART_WIDTH) / 2))
  (( target_offset < 0 )) && target_offset=0
  start_offset=$((-ART_WIDTH))
  travel=$((target_offset - start_offset))

  animation_ms=$((duration_ms / 4))
  (( animation_ms > 900 )) && animation_ms=900
  frame_ms=50
  frame_count=$((animation_ms / frame_ms))
  (( frame_count < 1 )) && frame_count=1

  for ((frame = 0; frame <= frame_count; frame++)); do
    offset=$((start_offset + (travel * frame / frame_count)))
    draw_art_screen "$offset" "♪ Playing"
    if (( frame < frame_count )); then
      sleep_ms "$frame_ms"
    fi
  done

  remaining_ms=$(((START_TIME + lyric_end_ms) - $(get_time_ms)))
  if (( remaining_ms > 0 )); then
    sleep_ms "$remaining_ms"
  fi
}

TERM_WIDTH=80
TERM_HEIGHT=24
update_terminal_size
trap update_terminal_size WINCH

TTY_STATE="$(stty -g < /dev/tty 2>/dev/null || true)"
if [[ -n "$TTY_STATE" ]]; then
  stty -echo -icanon min 1 time 0 < /dev/tty
fi

printf '\033[?1049h\033[?25l' # Enter alternate screen and hide cursor

MAIN_PID=$$
perl -e '
  my $parent = $ARGV[0];
  open(my $tty, "<", "/dev/tty") or exit;
  while (sysread($tty, my $key, 1)) {
    if ($key eq "\e" || $key eq "q" || $key eq "Q") {
      kill "TERM", $parent;
      exit;
    }
  }
' "$MAIN_PID" &
KEY_PID=$!

mpv \
  --no-video \
  --really-quiet \
  --no-terminal \
  "$SONG_FILE" &

PLAYER_PID=$!
START_TIME="$(get_time_ms)"

for ((index = 0; index < ${#timestamps[@]}; index++)); do
  lyric_time="${timestamps[$index]}"
  current_lyric="${lyrics[$index]}"

  if (( index + 1 < ${#lyrics[@]} )); then
    next_time="${timestamps[$((index + 1))]}"
  else
    next_time=$((lyric_time + 5000))
  fi

  while true; do
    now="$(get_time_ms)"
    elapsed=$((now - START_TIME))
    remaining=$((lyric_time - elapsed))

    if (( remaining <= 0 )); then
      break
    fi

    countdown="$(awk -v ms="$remaining" 'BEGIN { printf "%.1f", ms / 1000 }')"

    if (( index == 0 )); then
      draw_screen "♪" "♪ Playing"
    else
      draw_screen "♪" "Next line in ${countdown}s"
    fi

    if (( remaining > 250 )); then
      sleep_ms 250
    else
      sleep_ms "$remaining"
    fi
  done

  line_duration=$((next_time - lyric_time))

  animate_line "$current_lyric" "$line_duration" "$next_time"
done

wait "$PLAYER_PID"
