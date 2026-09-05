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


echo "== classify_udev_props"
assert_eq "$(classify_udev_props $'ID_CDROM=1\n')" "BLANK:NONE" "udev: no media"
assert_eq "$(classify_udev_props $'ID_CDROM_MEDIA=1\nID_CDROM_MEDIA_STATE=blank\n')" "BLANK:YES" "udev: blank DVD"
assert_eq "$(classify_udev_props $'ID_CDROM_MEDIA=1\nID_CDROM_MEDIA_STATE=blank\n' 5000000000)" "BLANK:TOO_SMALL" "udev: ISO larger than DVD-5"
assert_eq "$(classify_udev_props $'ID_CDROM_MEDIA=1\nID_FS_TYPE=iso9660\n')" "BLANK:NO" "udev: already has a filesystem"

echo "== iso_need_bytes"
assert_eq "$(iso_need_bytes)" "5237243904" "DVD-5 + 512MiB slack"

echo "== optical_dev_path_ok"
assert_eq "$(optical_dev_path_ok /dev/sr0 && echo yes || echo no)" "yes" "sr0 accepted"
assert_eq "$(optical_dev_path_ok /dev/sr12 && echo yes || echo no)" "yes" "sr12 accepted"
assert_eq "$(optical_dev_path_ok /dev/sda && echo yes || echo no)" "no" "sda rejected"
assert_eq "$(optical_dev_path_ok /dev/nvme0n1 && echo yes || echo no)" "no" "nvme rejected"
assert_eq "$(optical_dev_path_ok /dev/sr0foo && echo yes || echo no)" "no" "sr0foo rejected"
assert_eq "$(optical_dev_path_ok /tmp/sr0 && echo yes || echo no)" "no" "tmp path rejected"
assert_eq "$(optical_dev_path_ok /dev/../sr0 && echo yes || echo no)" "no" "dotdot rejected"
assert_eq "$(optical_dev_path_ok '' && echo yes || echo no)" "no" "empty rejected"

echo "== iso output safety"
iso_tmp=$(mktemp -d)
rt=""
trap 'rm -rf "$iso_tmp" "$rt"' EXIT
echo payload > "$iso_tmp/ok.iso"
assert_eq "$(iso_is_safe_output "$iso_tmp/ok.iso" && echo yes || echo no)" "yes" "owned regular file is safe"
assert_eq "$(iso_is_safe_output "$iso_tmp/new.iso" && echo yes || echo no)" "yes" "missing dest in writable dir is safe"
ln -s /etc/passwd "$iso_tmp/link.iso"
assert_eq "$(iso_is_safe_output "$iso_tmp/link.iso" && echo yes || echo no)" "no" "symlink dest rejected"
mkfifo "$iso_tmp/fifo.iso"
assert_eq "$(iso_is_safe_output "$iso_tmp/fifo.iso" && echo yes || echo no)" "no" "fifo dest rejected"

echo secret > "$iso_tmp/victim"
echo data > "$iso_tmp/src.iso"
ln -s "$iso_tmp/victim" "$iso_tmp/dest.iso"
if install_iso_output "$iso_tmp/src.iso" "$iso_tmp/dest.iso"; then
  echo "FAIL  install_iso_output must refuse symlink dest"
  fail=$((fail + 1))
else
  echo "ok  install_iso_output refuses symlink dest"
  pass=$((pass + 1))
fi
assert_eq "$(cat "$iso_tmp/victim")" "secret" "symlink target not overwritten"
assert_eq "$(test -L "$iso_tmp/dest.iso" && echo yes || echo no)" "yes" "attacker symlink left in place"

echo data2 > "$iso_tmp/src2.iso"
assert_eq "$(install_iso_output "$iso_tmp/src2.iso" "$iso_tmp/fresh.iso" && echo yes || echo no)" "yes" "install to new regular path"
assert_eq "$(test -f "$iso_tmp/fresh.iso" && ! test -L "$iso_tmp/fresh.iso" && echo yes || echo no)" "yes" "dest is a regular file"
fp=$(iso_fingerprint "$iso_tmp/fresh.iso")
if safe_unlink_iso "$iso_tmp/link.iso"; then
  echo "FAIL  safe_unlink_iso must refuse symlink"
  fail=$((fail + 1))
else
  echo "ok  safe_unlink_iso refuses symlink"
  pass=$((pass + 1))
fi
assert_eq "$(test -L "$iso_tmp/link.iso" && echo yes || echo no)" "yes" "symlink not removed"
assert_eq "$(test -f /etc/passwd && echo yes || echo no)" "yes" "symlink target not deleted"
rm -f "$iso_tmp/fresh.iso"
echo replaced > "$iso_tmp/fresh.iso"
if safe_unlink_iso "$iso_tmp/fresh.iso" "$fp"; then
  echo "FAIL  safe_unlink_iso must refuse fingerprint mismatch"
  fail=$((fail + 1))
else
  echo "ok  safe_unlink_iso refuses fingerprint mismatch"
  pass=$((pass + 1))
fi
assert_eq "$(test -f "$iso_tmp/fresh.iso" && echo yes || echo no)" "yes" "mismatched file kept"
fp2=$(iso_fingerprint "$iso_tmp/fresh.iso")
assert_eq "$(safe_unlink_iso "$iso_tmp/fresh.iso" "$fp2" && echo yes || echo no)" "yes" "matching fingerprint unlinked"
assert_eq "$(test -e "$iso_tmp/fresh.iso" && echo yes || echo no)" "no" "safe unlink removed our file"

echo "== runtime dir safety"
rt=$(mktemp -d)
chmod 700 "$rt"
VIDEO_TO_DVD_RUNTIME_DIR="$rt" init_runtime_state
assert_eq "$(test -f "$LOG" && ! test -L "$LOG" && echo yes || echo no)" "yes" "log is a regular file in private dir"
assert_eq "$(stat -c %a "$LOG")" "600" "log mode 600"
assert_eq "$(stat -c %a "$rt")" "700" "runtime dir mode 700"
ln -sf /etc/passwd "$rt/evil.log"
# Recreate after planting a symlink at the log path
LOG="$rt/evil.log"
PGID_FILE="$rt/job.pgid"
RUNTIME_DIR="$rt"
assert_eq "$(safe_create_file "$LOG" && ! test -L "$LOG" && test -f "$LOG" && echo yes || echo no)" "yes" "safe_create_file replaces log symlink"
assert_eq "$(test -f /etc/passwd && echo yes || echo no)" "yes" "log symlink target not truncated"
mkfifo "$rt/fifo.log"
assert_eq "$(safe_create_file "$rt/fifo.log" && echo yes || echo no)" "no" "FIFO rejected"

echo "== log size bound"
old_max=$MAX_LOG_BYTES
MAX_LOG_BYTES=64
LOG="$rt/bound.log"
: > "$LOG"
printf '%s\n' "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF extra" >> "$LOG"
enforce_log_bound
sz=$(stat -c %s "$LOG")
if (( sz <= 64 )); then
  echo "ok  enforce_log_bound caps log"
  pass=$((pass + 1))
else
  echo "FAIL  enforce_log_bound caps log"
  echo "      size: $sz"
  fail=$((fail + 1))
fi
MAX_LOG_BYTES=$old_max

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
