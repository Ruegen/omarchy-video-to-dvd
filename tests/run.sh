#!/bin/bash
# Unit tests for video-to-dvd.sh helpers. No disc, no ffmpeg encode.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/video-to-dvd.sh"

pass=0
fail=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    echo "ok  $name"
    pass=$((pass + 1))
  else
    echo "FAIL  $name"
    echo "      want: $want"
    echo "      got:  $got"
    fail=$((fail + 1))
  fi
}

assert_file_eq() {
  local file="$1" want="$2" name="$3"
  local got
  got=$(classify_blank "$(cat "$file")" "${4:-}")
  assert_eq "$got" "$want" "$name"
}

echo "== eta_status (wall-clock leftover, not movie length)"
# 107 min source at 8x with a little encoded → ~13 min left, never 107
assert_eq "$(eta_status 6420 80 10 8.0 1)" "encoding-eta|13|1" "8x speed on 107 min source is ~13 min"
assert_eq "$(eta_status 6420 80 10 '' 1)" "encoding-eta|13|1" "wall-clock average matches 8x"
assert_eq "$(eta_status 6420 2 2 '' 0)" "encoding-pct|0" "too early: percent only"
assert_eq "$(eta_status 6420 6380 800 8.0 99)" "encoding-finishing|99" "under 45s leftover: finishing"
assert_eq "$(eta_status 6420 5900 740 8.0 91)" "encoding-eta|1|91" "under 90s leftover: 1 min"
assert_eq "$(eta_status 6420 2 2 0.05 0)" "encoding-pct|0" "speed too low and too early: percent only"
# leftover_wall > 3h is untrusted
assert_eq "$(eta_status 20000 1 5 0.3 0)" "encoding-pct|0" "absurd leftover: percent only"

got="$(eta_status 6420 80 10 8.0 1)"
if [[ "$got" == *"|107|"* || "$got" == *"|107" ]]; then
  echo "FAIL  must not report movie length as leftover"
  echo "      got: $got"
  fail=$((fail + 1))
else
  echo "ok  must not report movie length as leftover"
  pass=$((pass + 1))
fi

echo "== classify_blank"
FIX="$ROOT/tests/fixtures"
assert_file_eq "$FIX/mediainfo-blank.txt" "BLANK:YES" "blank DVD+RW"
assert_file_eq "$FIX/mediainfo-complete.txt" "BLANK:NO" "complete disc is not blank"
assert_file_eq "$FIX/mediainfo-empty-tray.txt" "BLANK:NONE" "empty tray / ASC=3Ah"
assert_file_eq "$FIX/mediainfo-appendable.txt" "BLANK:YES" "appendable with free blocks"
assert_file_eq "$FIX/mediainfo-too-small.txt" "BLANK:TOO_SMALL" "blank but too small" "1048576"
assert_eq "$(classify_blank '')" "BLANK:NO" "empty mediainfo is not blank"

echo "== ffmpeg progress parse"
ffline='frame=  123 fps= 45 q=2.0 size=    1234kB time=01:47:00.12 bitrate=2053.4kbits/s speed=8.04x'
assert_eq "$(parse_ffmpeg_time_seconds "$ffline")" "6420" "time=01:47:00 → 6420s"
assert_eq "$(parse_ffmpeg_speed "$ffline")" "8.04" "speed=8.04x"
assert_eq "$(parse_ffmpeg_time_seconds 'frame=1 fps=0')" "" "no time= is empty"
assert_eq "$(parse_ffmpeg_speed 'frame=1 time=00:00:01.00')" "" "no speed= is empty"

echo "== growisofs CR progress"
got=$(printf '%s' $'start\r5.2 percent\r10.0 percent\ndone\n' | burn_progress_lines | paste -sd'|' -)
assert_eq "$got" "PROGRESS:BURN:start|PROGRESS:BURN:5.2 percent|PROGRESS:BURN:10.0 percent|PROGRESS:BURN:done" "CR updates become one line each"

echo "== iso_need_bytes"
assert_eq "$(iso_need_bytes)" "5237243904" "DVD-5 + 512MiB slack"

echo "== i18n keys"
en_keys=$(python3 -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1])))))' "$ROOT/i18n/en.json")
de_keys=$(python3 -c 'import json,sys; print("\n".join(sorted(json.load(open(sys.argv[1])))))' "$ROOT/i18n/de.json")
assert_eq "$de_keys" "$en_keys" "de.json keys match en.json"

echo
echo "$pass passed, $fail failed"
if (( fail > 0 )); then
  exit 1
fi
exit 0
