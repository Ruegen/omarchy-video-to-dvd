#!/bin/bash
set -euo pipefail

# Line-buffer stdout when piped so QML sees SETUP:/PROGRESS: immediately.
# Skip when sourced (tests) so we do not re-exec.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [[ -z "${VIDEO_TO_DVD_STDBUF:-}" && ! -t 1 ]] && command -v stdbuf >/dev/null 2>&1; then
  export VIDEO_TO_DVD_STDBUF=1
  exec stdbuf -oL -eL /bin/bash "$0" "$@"
fi

DVD_BYTES=4700372992      # DVD-5 (4.7GB marketing size)
OVERHEAD=0.94              # headroom for VIDEO_TS/ISO overhead
AUDIO_KBPS=192
ABS_MIN_VBITRATE=500
MAX_VBITRATE=8000
# Private runtime dir only (never world-writable /tmp/video-to-dvd.*).
RUNTIME_DIR=""
LOG=""
PGID_FILE=""
MAX_LOG_BYTES="${VIDEO_TO_DVD_MAX_LOG_BYTES:-1048576}"
MAX_CAPTURE_BYTES="${VIDEO_TO_DVD_MAX_CAPTURE_BYTES:-65536}"
TIMEOUT_FFPROBE="${VIDEO_TO_DVD_TIMEOUT_FFPROBE:-30}"
TIMEOUT_FFMPEG="${VIDEO_TO_DVD_TIMEOUT_FFMPEG:-28800}"
TIMEOUT_DVDAUTHOR="${VIDEO_TO_DVD_TIMEOUT_DVDAUTHOR:-1800}"
TIMEOUT_GENISO="${VIDEO_TO_DVD_TIMEOUT_GENISO:-1800}"
TIMEOUT_GROWISOFS="${VIDEO_TO_DVD_TIMEOUT_GROWISOFS:-7200}"
TIMEOUT_EJECT="${VIDEO_TO_DVD_TIMEOUT_EJECT:-30}"
TIMEOUT_MEDIAINFO="${VIDEO_TO_DVD_TIMEOUT_MEDIAINFO:-8}"
WORK_DIR=""

fail() {
  echo "RESULT:ERROR:$1"
  return 1
}

current_uid() {
  id -u
}

runtime_dir_ok() {
  local dir="${1:-}"
  [[ -n "$dir" && -d "$dir" && ! -L "$dir" ]] || return 1
  [[ "$(stat -c '%u %a' "$dir")" == "$(current_uid) 700" ]]
}

# Exclusive regular-file create: no symlink/FIFO follow.
safe_create_file() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  if [[ -L "$path" ]]; then
    unlink -- "$path" || return 1
  fi
  if [[ -e "$path" ]]; then
    [[ -f "$path" && ! -p "$path" && ! -S "$path" ]] || return 1
    [[ "$(stat -c '%u' "$path")" == "$(current_uid)" ]] || return 1
    chmod 600 -- "$path" || return 1
    return 0
  fi
  if command -v dd >/dev/null 2>&1; then
    dd if=/dev/null of="$path" conv=excl oflag=nofollow,noctty status=none 2>/dev/null \
      || (umask 077; set -o noclobber; : > "$path") || return 1
  else
    (umask 077; set -o noclobber; : > "$path") || return 1
  fi
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(stat -c '%u' "$path")" == "$(current_uid)" ]] || return 1
  chmod 600 -- "$path"
}

init_runtime_state() {
  if runtime_dir_ok "$RUNTIME_DIR" && [[ -n "$LOG" && -n "$PGID_FILE" ]]; then
    safe_create_file "$LOG" || return 1
    safe_create_file "$PGID_FILE" || return 1
    return 0
  fi

  local candidate parent
  if [[ -n "${VIDEO_TO_DVD_RUNTIME_DIR:-}" ]]; then
    candidate="$VIDEO_TO_DVD_RUNTIME_DIR"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" && -d "$XDG_RUNTIME_DIR" && ! -L "$XDG_RUNTIME_DIR" ]]; then
    candidate="${XDG_RUNTIME_DIR}/video-to-dvd"
  else
    candidate="/tmp/video-to-dvd-$(current_uid)"
  fi

  parent=$(dirname -- "$candidate")
  if [[ -L "$candidate" ]] || [[ ! -d "$parent" ]]; then
    candidate=$(mktemp -d "${TMPDIR:-/tmp}/video-to-dvd.XXXXXX") || return 1
    chmod 700 -- "$candidate" || return 1
  elif [[ ! -e "$candidate" ]]; then
    mkdir -m 0700 -- "$candidate" || {
      candidate=$(mktemp -d "${TMPDIR:-/tmp}/video-to-dvd.XXXXXX") || return 1
      chmod 700 -- "$candidate" || return 1
    }
  fi
  runtime_dir_ok "$candidate" || return 1

  RUNTIME_DIR="$candidate"
  LOG="${VIDEO_TO_DVD_LOG:-$RUNTIME_DIR/convert.log}"
  PGID_FILE="${VIDEO_TO_DVD_PGID_FILE:-$RUNTIME_DIR/job.pgid}"
  case "$LOG" in
    "$RUNTIME_DIR"/*) ;;
    *) LOG="$RUNTIME_DIR/convert.log" ;;
  esac
  case "$PGID_FILE" in
    "$RUNTIME_DIR"/*) ;;
    *) PGID_FILE="$RUNTIME_DIR/job.pgid" ;;
  esac
  safe_create_file "$LOG" || return 1
  safe_create_file "$PGID_FILE" || return 1
}

enforce_log_bound() {
  local sz tmp
  [[ -n "$LOG" && -f "$LOG" && ! -L "$LOG" ]] || return 0
  sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
  [[ "$sz" =~ ^[0-9]+$ ]] || return 0
  if (( sz > MAX_LOG_BYTES )); then
    tmp="${LOG}.trim"
    tail -c $((MAX_LOG_BYTES / 2)) "$LOG" > "$tmp" 2>/dev/null || return 0
    if [[ -f "$tmp" && ! -L "$tmp" ]]; then
      mv -f -- "$tmp" "$LOG"
      chmod 600 -- "$LOG" || true
    else
      rm -f -- "$tmp"
    fi
  fi
}

# Pass stdin through; copy into the log until MAX_LOG_BYTES.
pipe_log() {
  local n=0 sz
  if [[ -n "$LOG" && -f "$LOG" && ! -L "$LOG" ]]; then
    sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
    [[ "$sz" =~ ^[0-9]+$ ]] && n=$sz
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    if [[ -n "$LOG" && -f "$LOG" && ! -L "$LOG" ]] && (( n < MAX_LOG_BYTES )); then
      printf '%s\n' "$line" >> "$LOG" || true
      n=$((n + ${#line} + 1))
    fi
  done
}

# Retain at most max bytes while still forwarding every line.
retain_limited() {
  local dest="$1" max="${2:-$MAX_CAPTURE_BYTES}" n=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$line"
    if (( n < max )) && [[ -n "$dest" && -f "$dest" && ! -L "$dest" ]]; then
      printf '%s\n' "$line" >> "$dest" || true
      n=$((n + ${#line} + 1))
    fi
  done
}

run_deadline() {
  local secs="$1"
  shift
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=60
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=15s --signal=TERM "$secs" "$@" || rc=$?
  else
    "$@" || rc=$?
  fi
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    kill_process_group_children
  fi
  return "$rc"
}

capture_limited() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --kill-after=5s --signal=TERM "$secs" "$@" 2>&1 | head -c "$MAX_CAPTURE_BYTES" || true
  else
    "$@" 2>&1 | head -c "$MAX_CAPTURE_BYTES" || true
  fi
}

printable_only() {
  printf '%s' "${1:-}" | tr -cd '[:print:]'
}

optical_dev_path_ok() {
  [[ "${1:-}" =~ ^/dev/sr[0-9]+$ ]]
}

optical_dev_identity() {
  local dev="${1:-}"
  local majmin devpath
  optical_dev_path_ok "$dev" || return 1
  [[ -b "$dev" ]] || return 1
  majmin=$(stat -c '%t:%T' "$dev" 2>/dev/null) || return 1
  [[ -n "$majmin" && "$majmin" != "0:0" ]] || return 1
  devpath=$(udevadm info --query=property "$dev" 2>/dev/null | sed -n 's/^DEVPATH=//p' | tail -n1 || true)
  printf '%s\t%s' "$majmin" "$devpath"
}

validate_optical_dev() {
  local raw="${1:-}" canon line type name props
  optical_dev_path_ok "$raw" || return 1
  if [[ -L "$raw" ]]; then
    canon=$(readlink -f -- "$raw" 2>/dev/null) || return 1
    optical_dev_path_ok "$canon" || return 1
    raw="$canon"
  fi
  [[ -b "$raw" && ! -L "$raw" ]] || return 1
  line=$(lsblk -d -n -P -o NAME,TYPE "$raw" 2>/dev/null || true)
  [[ -n "$line" ]] || return 1
  type=$(lsblk_kv "$line" TYPE)
  name=$(lsblk_kv "$line" NAME)
  [[ "$type" == "rom" ]] || return 1
  [[ "$name" =~ ^sr[0-9]+$ ]] || return 1
  [[ "/dev/${name}" == "$raw" ]] || return 1
  props=$(capture_limited 5 udevadm info --query=property "$raw" || true)
  if [[ -n "$props" ]]; then
    if ! printf '%s\n' "$props" | grep -qx 'ID_CDROM=1'; then
      if ! printf '%s\n' "$props" | grep -qx 'ID_TYPE=cd'; then
        return 1
      fi
    fi
  fi
  printf '%s\n' "$raw"
}

require_optical_dev() {
  local raw="${1:-}" expected="${2:-}" got ident
  got=$(validate_optical_dev "$raw") || return 1
  if [[ -n "$expected" ]]; then
    ident=$(optical_dev_identity "$got") || return 1
    [[ "$ident" == "$expected" ]] || return 1
  fi
  printf '%s\n' "$got"
}

iso_is_safe_output() {
  local path="${1:-}" parent
  [[ -n "$path" && "$path" != "-" ]] || return 1
  if [[ -L "$path" || -p "$path" || -S "$path" || -b "$path" || -c "$path" || -d "$path" ]]; then
    return 1
  fi
  if [[ -e "$path" ]]; then
    [[ -f "$path" ]] || return 1
    [[ "$(stat -c '%u' "$path")" == "$(current_uid)" ]] || return 1
  fi
  parent=$(dirname -- "$path")
  [[ -d "$parent" ]] || return 1
}

iso_fingerprint() {
  local path="${1:-}"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  stat -c '%d:%i:%u' "$path"
}

# Move a privately created ISO onto dest without following dest.
install_iso_output() {
  local src="${1:-}" dest="${2:-}"
  [[ -f "$src" && ! -L "$src" ]] || return 1
  [[ "$(stat -c '%u' "$src")" == "$(current_uid)" ]] || return 1
  iso_is_safe_output "$dest" || return 1
  if [[ -L "$dest" ]]; then
    return 1
  fi
  if [[ -e "$dest" ]]; then
    [[ -f "$dest" ]] || return 1
    [[ "$(stat -c '%u' "$dest")" == "$(current_uid)" ]] || return 1
    rm -f -- "$dest"
    if [[ -e "$dest" || -L "$dest" ]]; then
      return 1
    fi
  fi
  mv -T -- "$src" "$dest" || return 1
  [[ -f "$dest" && ! -L "$dest" ]]
}

safe_unlink_iso() {
  local path="${1:-}" expected="${2:-}" fp owner
  [[ -n "$path" ]] || return 1
  if [[ -L "$path" || ! -f "$path" ]]; then
    return 1
  fi
  owner=$(stat -c '%u' "$path")
  [[ "$owner" == "$(current_uid)" ]] || return 1
  fp=$(stat -c '%d:%i:%u' "$path")
  if [[ -n "$expected" && "$fp" != "$expected" ]]; then
    return 1
  fi
  rm -f -- "$path"
}

cleanup_work() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
  WORK_DIR=""
}

kill_process_group_children() {
  local pids
  pids=$(pgrep -g $$ 2>/dev/null | grep -vx "$$" || true)
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill -TERM $pids 2>/dev/null || true
    sleep 0.15
    pids=$(pgrep -g $$ 2>/dev/null | grep -vx "$$" || true)
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill -KILL $pids 2>/dev/null || true
    fi
  fi
}

on_cancel_signal() {
  set +e
  trap - EXIT TERM INT HUP
  kill_process_group_children
  cleanup_work
  rm -f "$PGID_FILE"
  echo "RESULT:ERROR:cancelled"
  exit 143
}

setup_job_traps() {
  if ! init_runtime_state; then
    echo "RESULT:ERROR:runtime-state"
    exit 1
  fi
  printf '%s\n' "$$" > "$PGID_FILE"
  echo "PGID:$$"
  trap 'cleanup_work; rm -f "$PGID_FILE"' EXIT
  trap on_cancel_signal TERM INT HUP
}

# Re-exec under setsid so this job is a session/process-group leader.
# QML can then reap ffmpeg/dvdauthor/genisoimage/growisofs with
# Process.signal(15) and `kill -- -$pgid`.
ensure_session() {
  if [[ -n "${VIDEO_TO_DVD_SESSION:-}" ]]; then
    return 0
  fi
  export VIDEO_TO_DVD_SESSION=1
  if command -v stdbuf >/dev/null 2>&1; then
    exec setsid --wait stdbuf -oL -eL /bin/bash "$0" "$MODE" "$@"
  fi
  exec setsid --wait /bin/bash "$0" "$MODE" "$@"
}

# Freedesktop event sound (complete.oga). Respects the session sound theme.
play_event_sound() {
  local id="${1:-complete}"
  local file="/usr/share/sounds/freedesktop/stereo/${id}.oga"
  if command -v canberra-gtk-play >/dev/null 2>&1; then
    canberra-gtk-play -i "$id" >/dev/null 2>&1 && return 0
  fi
  if [[ -f "$file" ]]; then
    if command -v mpv >/dev/null 2>&1; then
      mpv --no-video --really-quiet "$file" >/dev/null 2>&1 && return 0
    fi
    if command -v paplay >/dev/null 2>&1; then
      paplay "$file" >/dev/null 2>&1 && return 0
    fi
    if command -v pw-play >/dev/null 2>&1; then
      pw-play "$file" >/dev/null 2>&1 && return 0
    fi
  fi
  return 0
}

notify_user() {
  local title="${1:-}"
  local body="${2:-}"
  local sound="${3:-}"
  [[ -n "$title" ]] || return 0
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send --app-name "Video to DVD" -u normal "$title" "$body" || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name "Video to DVD" -u normal "$title" "$body" || true
  fi
  if [[ -n "$sound" ]]; then
    play_event_sound "$sound" || true
  fi
}

eject_disc() {
  local dev
  dev=$(resolve_dev "${1:-}" || true)
  if [[ $# -lt 1 && -n "$dev" ]]; then
    set -- "$dev"
  fi
  maybe_newgrp_wrap "$dev" "$@"
  if [[ -z "$dev" ]]; then
    echo "RESULT:ERROR:eject-failed"
    return 1
  fi
  if try_eject "$dev"; then
    echo "RESULT:OK:ejected"
    return 0
  fi
  echo "RESULT:ERROR:eject-failed"
  return 1
}

lsblk_kv() {
  local line="$1" key="$2"
  if [[ "$line" =~ ${key}=\"([^\"]*)\" ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

drive_human_label() {
  local tran="${1-}" model="${2-}"
  local m t
  m="${model#"${model%%[![:space:]]*}"}"
  m="${m%"${m##*[![:space:]]}"}"
  t=$(printf '%s' "$tran" | tr '[:upper:]' '[:lower:]')
  case "$m" in
    ""|"Mass Storage Device"|"USB Mass Storage Device"|"USB Mass Storage")
      if [[ "$t" == "usb" ]]; then
        printf '%s' "drive.usb"
      else
        printf '%s' "drive.internal"
      fi
      ;;
    *)
      printf '%s' "$m"
      ;;
  esac
}

list_optical_drives() {
  local line name type tran model path label base p already i j dup
  local -a paths=() labels=()

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    type=$(lsblk_kv "$line" TYPE)
    [[ "$type" == "rom" ]] || continue
    name=$(lsblk_kv "$line" NAME)
    [[ "$name" =~ ^sr[0-9]+$ ]] || continue
    path="/dev/${name}"
    optical_dev_path_ok "$path" || continue
    [[ -b "$path" ]] || continue
    tran=$(lsblk_kv "$line" TRAN)
    model=$(printable_only "$(lsblk_kv "$line" MODEL)")
    label=$(printable_only "$(drive_human_label "$tran" "$model")")
    paths+=("$path")
    labels+=("$label")
  done < <(lsblk -d -n -P -o NAME,TYPE,TRAN,MODEL 2>/dev/null || true)

  shopt -s nullglob
  for p in /dev/sr[0-9]*; do
    already=0
    if ((${#paths[@]} > 0)); then
      for name in "${paths[@]}"; do
        if [[ "$name" == "$p" ]]; then
          already=1
          break
        fi
      done
    fi
    (( already )) && continue
    optical_dev_path_ok "$p" || continue
    [[ -b "$p" ]] || continue
    tran=""
    model=""
    line=$(lsblk -d -n -P -o NAME,TYPE,TRAN,MODEL "$p" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
      tran=$(lsblk_kv "$line" TRAN)
      model=$(lsblk_kv "$line" MODEL)
    fi
    paths+=("$p")
    labels+=("$(printable_only "$(drive_human_label "$tran" "$model")")")
  done
  shopt -u nullglob

  for i in "${!paths[@]}"; do
    dup=0
    for j in "${!paths[@]}"; do
      if [[ $i -ne $j && "${labels[$i]}" == "${labels[$j]}" ]]; then
        dup=1
        break
      fi
    done
    if (( dup )); then
      base="${paths[$i]##*/}"
      labels[$i]="${labels[$i]} (${base})"
    fi
  done

  for i in "${!paths[@]}"; do
    printf 'DEV:%s|%s\n' "${paths[$i]}" "${labels[$i]}"
  done
}

first_dvd_dev() {
  local line path
  while IFS= read -r line; do
    [[ "$line" == DEV:* ]] || continue
    path="${line#DEV:}"
    path="${path%%|*}"
    if [[ -n "$path" ]] && validate_optical_dev "$path" >/dev/null; then
      printf '%s\n' "$path"
      return 0
    fi
  done < <(list_optical_drives)
  return 1
}

resolve_dev() {
  local dev="${1:-}"
  if [[ -n "$dev" ]]; then
    validate_optical_dev "$dev"
    return
  fi
  first_dvd_dev
}

in_optical_session() {
  id -nG 2>/dev/null | tr ' ' '\n' | grep -qx optical
}

in_optical_group() {
  local user="${USER:-$(id -un)}"
  getent group optical 2>/dev/null | awk -F: '{print $4}' | tr ',' '\n' | grep -qx "$user"
}

drive_is_writable() {
  local dev="${1:-}"
  optical_dev_path_ok "$dev" || return 1
  [[ -b "$dev" ]] && test -w "$dev"
}

# sg is often missing; util-linux newgrp accepts: newgrp <group> -c <command>
maybe_newgrp_wrap() {
  local dev="${1:-}"
  if [[ -n "${VIDEO_TO_DVD_NEWGRP:-}" ]]; then
    return 0
  fi
  [[ -n "$dev" && -e "$dev" ]] || return 0
  optical_dev_path_ok "$dev" || return 0
  if drive_is_writable "$dev"; then
    return 0
  fi
  in_optical_group || return 0
  export VIDEO_TO_DVD_NEWGRP=1
  local quoted
  quoted=$(printf '%q ' /bin/bash "$0" "$MODE" "$@")
  if command -v sg >/dev/null 2>&1; then
    exec sg optical -c "$quoted"
  fi
  if command -v newgrp >/dev/null 2>&1; then
    exec newgrp optical -c "$quoted"
  fi
  return 0
}

# DVD-5 plus 512MiB slack so the ISO can land next to the video.
iso_need_bytes() {
  echo $((DVD_BYTES + 536870912))
}

dir_avail_bytes() {
  local dir="$1"
  df -B1 --output=avail "$dir" 2>/dev/null | awk 'NR==2 { gsub(/[[:space:]]/, ""); print }'
}

space_check() {
  local target="${1:-}"
  local dir avail need
  need=$(iso_need_bytes)
  if [[ -z "$target" ]]; then
    echo "RESULT:ERROR:not-enough-space"
    return 1
  fi
  if [[ -d "$target" ]]; then
    dir="$target"
  else
    dir=$(dirname -- "$target")
  fi
  if [[ ! -d "$dir" ]]; then
    echo "RESULT:ERROR:not-enough-space"
    return 1
  fi
  avail=$(dir_avail_bytes "$dir")
  if [[ ! "$avail" =~ ^[0-9]+$ ]] || (( avail < need )); then
    echo "RESULT:ERROR:not-enough-space"
    return 1
  fi
  echo "SPACE:ok:${avail}"
}

parse_ffmpeg_time_seconds() {
  local line="$1"
  if [[ "$line" =~ time=([0-9]+):([0-9]+):([0-9]+) ]]; then
    printf '%s' $((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]}))
  fi
}

parse_ffmpeg_speed() {
  local line="$1"
  if [[ "$line" =~ speed=([0-9]+([.][0-9]+)?)x ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# growisofs prints percent with CR; turn those into one line per update.
burn_progress_lines() {
  tr '\r' '\n' | while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "PROGRESS:BURN:$line"
  done
}

# Classify dvd+rw-mediainfo text. iso_size is bytes or empty.
classify_blank() {
  local info="$1"
  local iso_size="${2:-}"

  if printf '%s\n' "$info" | grep -qiE \
      'medium not present|no medium|not ready|cannot load|unable to (read|open)|no disc|no media|ASC=3Ah|Device not ready'; then
    echo "BLANK:NONE"
    return 0
  fi

  local is_blank=0
  if printf '%s\n' "$info" | grep -qiE 'Disc status:[[:space:]]*blank'; then
    is_blank=1
  elif printf '%s\n' "$info" | grep -qiE 'Disc status:[[:space:]]*(complete|appendable|incomplete)'; then
    if ! printf '%s\n' "$info" | grep -qiE 'Disc status:[[:space:]]*complete'; then
      is_blank=1
    fi
  elif printf '%s\n' "$info" | grep -qiE 'Mounted Media:[[:space:]]*[0-9A-Fa-f]+h,'; then
    echo "BLANK:NO"
    return 0
  fi

  if (( is_blank )); then
    local free_blocks
    free_blocks=$(printf '%s\n' "$info" | grep -iE 'Free Blocks|Free Space' | head -n1 | grep -oE '[0-9]+' || true)
    if [[ -n "$free_blocks" && -n "$iso_size" ]]; then
      local free_bytes=$((free_blocks * 2048))
      if (( free_bytes < iso_size )); then
        echo "BLANK:TOO_SMALL"
        return 0
      fi
    fi
    echo "BLANK:YES"
    return 0
  fi

  echo "BLANK:NO"
}

# udev properties (no SCSI I/O). USB trays wedge if we SIGKILL dvd+rw-mediainfo.
classify_udev_props() {
  local props="$1"
  local iso_size="${2:-}"
  local media state fstype

  media=$(printf '%s\n' "$props" | sed -n 's/^ID_CDROM_MEDIA=//p' | tail -n1)
  if [[ "$media" != "1" ]]; then
    echo "BLANK:NONE"
    return 0
  fi
  state=$(printf '%s\n' "$props" | sed -n 's/^ID_CDROM_MEDIA_STATE=//p' | tail -n1)
  fstype=$(printf '%s\n' "$props" | sed -n 's/^ID_FS_TYPE=//p' | tail -n1)
  if [[ "$state" == "blank" ]]; then
    if [[ -n "$iso_size" && "$iso_size" =~ ^[0-9]+$ ]] && (( iso_size > DVD_BYTES )); then
      echo "BLANK:TOO_SMALL"
      return 0
    fi
    echo "BLANK:YES"
    return 0
  fi
  if [[ -n "$fstype" ]]; then
    echo "BLANK:NO"
    return 0
  fi
  echo "BLANK:NO"
}

try_eject() {
  local raw="${1:-}"
  local dev ident
  init_runtime_state || true
  dev=$(require_optical_dev "$raw") || return 1
  ident=$(optical_dev_identity "$dev") || return 1
  {
    echo "=== eject $(date -Iseconds) dev=$dev ==="
  } >> "$LOG" 2>/dev/null || true
  enforce_log_bound
  sleep 1
  # Re-check identity immediately before unmount/eject.
  dev=$(require_optical_dev "$dev" "$ident") || return 1
  if command -v udisksctl >/dev/null 2>&1; then
    run_deadline "$TIMEOUT_EJECT" udisksctl unmount -b "$dev" >>"$LOG" 2>&1 || true
  fi
  run_deadline "$TIMEOUT_EJECT" umount "$dev" >>"$LOG" 2>&1 || true
  run_deadline "$TIMEOUT_EJECT" eject -i off "$dev" >>"$LOG" 2>&1 || true
  if command -v udisksctl >/dev/null 2>&1; then
    if run_deadline "$TIMEOUT_EJECT" udisksctl eject -b "$dev" >>"$LOG" 2>&1; then
      enforce_log_bound
      return 0
    fi
  fi
  run_deadline "$TIMEOUT_EJECT" eject -F "$dev" >>"$LOG" 2>&1 && { enforce_log_bound; return 0; }
  run_deadline "$TIMEOUT_EJECT" eject -r "$dev" >>"$LOG" 2>&1 && { enforce_log_bound; return 0; }
  run_deadline "$TIMEOUT_EJECT" eject -s "$dev" >>"$LOG" 2>&1 && { enforce_log_bound; return 0; }
  enforce_log_bound
  return 1
}

# Wall-clock leftover, not remaining source duration (encode is usually >> 1x).
eta_status() {
  local dur_i="$1" elapsed="$2" wall="$3" speed="${4:-}" pct_v="$5"
  local left_media=$((dur_i - elapsed)) left_wall="" mins
  (( left_media < 0 )) && left_media=0
  [[ -z "$pct_v" ]] && pct_v=0

  if [[ "$speed" =~ ^[0-9]+([.][0-9]+)?$ ]] && (( $(echo "$speed > 0.2" | bc) )); then
    left_wall=$(echo "scale=0; $left_media / $speed" | bc)
  elif (( wall >= 5 && elapsed >= 3 )); then
    left_wall=$(( left_media * wall / elapsed ))
  fi

  if [[ -z "$left_wall" ]] || (( left_wall > 10800 )); then
    printf '%s' "encoding-pct|${pct_v}"
    return
  fi
  if (( left_wall < 45 )); then
    printf '%s' "encoding-finishing|${pct_v}"
  elif (( left_wall < 90 )); then
    printf '%s' "encoding-eta|1|${pct_v}"
  else
    mins=$(( (left_wall + 30) / 60 ))
    printf '%s' "encoding-eta|${mins}|${pct_v}"
  fi
}

convert() {
  ensure_session "$@"
  local tv_std="${VIDEO_TO_DVD_STANDARD:-PAL}"
  tv_std="${tv_std^^}"
  if [[ "$tv_std" != "NTSC" ]]; then
    tv_std="PAL"
  fi

  local input="$1" output_iso="$2"
  setup_job_traps

  local ext="${input##*.}"
  ext="${ext,,}"
  case "$ext" in
    mp4|mkv|mov|avi|webm|m4v|ts|mts|m2ts|wmv|flv) ;;
    *)
      echo "PROGRESS:0:unsupported-format|.$ext"
      fail "unsupported-format"
      return 1
      ;;
  esac

  if [[ ! -f "$input" ]]; then
    fail "input-not-found"
    return 1
  fi

  if ! iso_is_safe_output "$output_iso"; then
    fail "iso-unsafe-path"
    return 1
  fi

  if ! space_check "$output_iso" >/dev/null; then
    fail "not-enough-space"
    return 1
  fi

  local work
  work=$(mktemp -d)
  WORK_DIR="$work"
  if ! init_runtime_state; then
    fail "runtime-state"
    return 1
  fi
  {
    echo "=== video-to-dvd convert $(date -Iseconds) ==="
    echo "input=$input"
    echo "output=$output_iso"
    echo "work=$work"
    echo "pgid=$$"
  } >> "$LOG"
  enforce_log_bound

  local dur dur_i have_dur=0
  dur=$(run_deadline "$TIMEOUT_FFPROBE" ffprobe -v error -show_entries format=duration -of csv=p=0 "$input" 2>>"$LOG" || true)
  enforce_log_bound
  dur_i=0
  if [[ "$dur" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    dur_i=${dur%.*}
    [[ -z "$dur_i" ]] && dur_i=0
    if (( dur_i >= 1 )); then
      have_dur=1
    fi
  fi

  # --- detect source dimensions & display aspect ratio ---
  local src_w src_h dar_raw src_ar
  src_w=$(run_deadline "$TIMEOUT_FFPROBE" ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$input" 2>>"$LOG" || true)
  src_h=$(run_deadline "$TIMEOUT_FFPROBE" ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$input" 2>>"$LOG" || true)
  dar_raw=$(run_deadline "$TIMEOUT_FFPROBE" ffprobe -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of csv=p=0 "$input" 2>>"$LOG" || true)
  enforce_log_bound

  if [[ "$dar_raw" =~ ^([0-9]+):([0-9]+)$ ]] && (( 10#${BASH_REMATCH[1]} > 0 && 10#${BASH_REMATCH[2]} > 0 )); then
    src_ar=$(echo "scale=8; ${BASH_REMATCH[1]} / ${BASH_REMATCH[2]}" | bc)
  elif [[ "$src_w" =~ ^[0-9]+$ && "$src_h" =~ ^[0-9]+$ ]] && (( src_h > 0 )); then
    src_ar=$(echo "scale=8; $src_w / $src_h" | bc)
  else
    src_ar="1.77777778"
  fi

  # DVD canvas is 720x576 (PAL) or 720x480 (NTSC). Choose 16:9 vs 4:3 by closeness to source DAR.
  local dar_169 dar_43 diff_169 diff_43 dvd_aspect_flag dvdauthor_vopts scale_filter target_arg fps_val
  dar_169=$(echo "scale=8; 16/9" | bc)
  dar_43=$(echo "scale=8; 4/3" | bc)
  diff_169=$(echo "scale=8; a=$src_ar - $dar_169; if (a<0) a=-a; a" | bc)
  diff_43=$(echo "scale=8; a=$src_ar - $dar_43; if (a<0) a=-a; a" | bc)

  if [[ "$tv_std" == "NTSC" ]]; then
    target_arg="ntsc-dvd"
    fps_val="30000/1001"
    if (( $(echo "$diff_169 <= $diff_43" | bc) )); then
      dvd_aspect_flag="16:9"
      dvdauthor_vopts="ntsc+16:9"
      scale_filter="scale=853:480:force_original_aspect_ratio=decrease,pad=853:480:(ow-iw)/2:(oh-ih)/2:black,scale=720:480,setdar=16/9,setsar=32/27"
    else
      dvd_aspect_flag="4:3"
      dvdauthor_vopts="ntsc+4:3"
      scale_filter="scale=640:480:force_original_aspect_ratio=decrease,pad=640:480:(ow-iw)/2:(oh-ih)/2:black,scale=720:480,setdar=4/3,setsar=8/9"
    fi
  else
    target_arg="pal-dvd"
    fps_val="25"
    if (( $(echo "$diff_169 <= $diff_43" | bc) )); then
      dvd_aspect_flag="16:9"
      dvdauthor_vopts="pal+16:9"
      scale_filter="scale=1024:576:force_original_aspect_ratio=decrease,pad=1024:576:(ow-iw)/2:(oh-ih)/2:black,scale=720:576,setdar=16/9,setsar=64/45"
    else
      dvd_aspect_flag="4:3"
      dvdauthor_vopts="pal+4:3"
      scale_filter="scale=768:576:force_original_aspect_ratio=decrease,pad=768:576:(ow-iw)/2:(oh-ih)/2:black,scale=720:576,setdar=4/3,setsar=12/11"
    fi
  fi

  local vbitrate=4000
  if (( have_dur )); then
    local target_bits audio_bits video_bits
    target_bits=$(echo "$DVD_BYTES * 8 * $OVERHEAD" | bc)
    audio_bits=$(echo "$AUDIO_KBPS * 1000 * $dur_i" | bc)
    video_bits=$(echo "$target_bits - $audio_bits" | bc)
    if (( $(echo "$video_bits > 0" | bc) )); then
      vbitrate=$(echo "$video_bits / $dur_i / 1000" | bc)
    else
      vbitrate=$ABS_MIN_VBITRATE
    fi
    # Upper clamp only. Do not raise a too-low rate up to 1000k (that overflows DVD-5).
    if (( vbitrate > MAX_VBITRATE )); then
      vbitrate=$MAX_VBITRATE
    fi
    if (( vbitrate < ABS_MIN_VBITRATE )); then
      vbitrate=$ABS_MIN_VBITRATE
    fi
  fi

  {
    echo "src=${src_w}x${src_h} dar_raw=$dar_raw src_ar=$src_ar"
    echo "aspect=$dvd_aspect_flag vopts=$dvdauthor_vopts vbitrate=${vbitrate}k duration=$dur have_dur=$have_dur"
    echo "vf=$scale_filter"
  } >> "$LOG"

  # --- check for AMD AMF hardware encoder ---
  local vcodec="mpeg2video"
  if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q "mpeg2_amf"; then
    vcodec="mpeg2_amf"
  fi

  echo "PROGRESS:1:analyzing|${src_w:-?}x${src_h:-?}|$dvd_aspect_flag|$tv_std"

  set +e
  set +o pipefail
  local encode_start last_progress_key=""
  encode_start=$(date +%s)
  run_deadline "$TIMEOUT_FFMPEG" ffmpeg -nostdin -y -i "$input" \
    -target "$target_arg" \
    -vf "$scale_filter" \
    -pix_fmt yuv420p \
    -r "$fps_val" \
    -c:v "$vcodec" \
    -aspect "$dvd_aspect_flag" \
    -b:v "${vbitrate}k" -maxrate 9000k -minrate 0 -bufsize 1835008 \
    -g 15 -bf 2 \
    -c:a ac3 -b:a "${AUDIO_KBPS}k" -ac 2 -ar 48000 \
    -f dvd \
    "$work/video.mpg" 2>&1 | tr '\r' '\n' | pipe_log | while IFS= read -r line; do
      elapsed=$(parse_ffmpeg_time_seconds "$line")
      if [[ -n "$elapsed" ]]; then
        if (( have_dur )); then
          pct=$(( elapsed * 70 / dur_i ))
          (( pct > 70 )) && pct=70
          (( pct < 1 )) && pct=1
          pct_v=$(( elapsed * 100 / dur_i ))
          (( pct_v > 99 )) && pct_v=99
          (( pct_v < 0 )) && pct_v=0
          speed=$(parse_ffmpeg_speed "$line")
          wall=$(( $(date +%s) - encode_start ))
          token=$(eta_status "$dur_i" "$elapsed" "$wall" "$speed" "$pct_v")
          key="${pct}:${token}"
          if [[ "$key" != "$last_progress_key" ]]; then
            echo "PROGRESS:${pct}:${token}"
            last_progress_key="$key"
          fi
        else
          echo "PROGRESS:1:encoding"
        fi
      fi
    done
  ff_status=${PIPESTATUS[0]}
  set -e
  set -o pipefail

  if [[ $ff_status -eq 124 || $ff_status -eq 137 ]]; then
    rm -rf "$work"
    WORK_DIR=""
    fail "timeout"
    return 1
  fi
  if [[ $ff_status -ne 0 ]] || [[ ! -s "$work/video.mpg" ]]; then
    rm -rf "$work"
    WORK_DIR=""
    fail "ffmpeg-encode-failed"
    return 1
  fi

  echo "PROGRESS:75:authoring"
  export VIDEO_FORMAT="$tv_std"
  set +e
  run_deadline "$TIMEOUT_DVDAUTHOR" dvdauthor -o "$work/dvd" -t -v "$dvdauthor_vopts" "$work/video.mpg" >>"$LOG" 2>&1
  da1=$?
  da2=1
  if [[ $da1 -eq 0 ]]; then
    run_deadline "$TIMEOUT_DVDAUTHOR" dvdauthor -o "$work/dvd" -T >>"$LOG" 2>&1
    da2=$?
  fi
  set -e
  enforce_log_bound

  if [[ $da1 -eq 124 || $da1 -eq 137 || $da2 -eq 124 || $da2 -eq 137 ]]; then
    rm -rf "$work"
    WORK_DIR=""
    fail "timeout"
    return 1
  fi
  if [[ $da1 -ne 0 || $da2 -ne 0 || ! -f "$work/dvd/VIDEO_TS/VIDEO_TS.IFO" ]]; then
    rm -rf "$work"
    WORK_DIR=""
    fail "dvdauthor-failed"
    return 1
  fi

  echo "PROGRESS:90:iso"
  if ! iso_is_safe_output "$output_iso"; then
    rm -rf "$work"
    WORK_DIR=""
    fail "iso-unsafe-path"
    return 1
  fi
  local iso_tmp iso_parent
  iso_parent=$(dirname -- "$output_iso")
  iso_tmp=$(mktemp -- "${iso_parent}/.v2dvd-XXXXXX.iso") || {
    rm -rf "$work"
    WORK_DIR=""
    fail "iso-build-failed"
    return 1
  }
  set +e
  run_deadline "$TIMEOUT_GENISO" genisoimage -dvd-video -V "DVD_VIDEO" -o "$iso_tmp" "$work/dvd" >>"$LOG" 2>&1
  iso_status=$?
  set -e
  enforce_log_bound

  if [[ $iso_status -eq 124 || $iso_status -eq 137 ]]; then
    rm -f -- "$iso_tmp"
    rm -rf "$work"
    WORK_DIR=""
    fail "timeout"
    return 1
  fi
  if [[ $iso_status -ne 0 || ! -s "$iso_tmp" ]]; then
    rm -f -- "$iso_tmp"
    rm -rf "$work"
    WORK_DIR=""
    fail "iso-build-failed"
    return 1
  fi
  if ! install_iso_output "$iso_tmp" "$output_iso"; then
    rm -f -- "$iso_tmp"
    rm -rf "$work"
    WORK_DIR=""
    fail "iso-unsafe-path"
    return 1
  fi

  rm -rf "$work"
  WORK_DIR=""
  rm -f "$PGID_FILE"
  echo "PROGRESS:100:done"
  echo "RESULT:OK:$output_iso"
}

check_blank() {
  local dev iso_size="${2:-}"
  dev=$(resolve_dev "${1:-}" || true)
  if [[ $# -lt 1 && -n "$dev" ]]; then
    set -- "$dev"
  fi
  # Read-only probe: never wrap in newgrp (that can hang with no TTY).
  if [[ -z "$dev" ]]; then
    echo "BLANK:NONE"
    return 0
  fi
  if [[ -n "$iso_size" && -f "$iso_size" && ! -L "$iso_size" ]]; then
    iso_size=$(stat -c %s "$iso_size")
  fi

  init_runtime_state || true
  # Re-check identity immediately before udev / SCSI probe.
  dev=$(require_optical_dev "$dev") || {
    echo "BLANK:NONE"
    return 0
  }

  local props verdict
  props=$(capture_limited 5 udevadm info --query=property "$dev" || true)
  if [[ -n "$props" ]]; then
    verdict=$(classify_udev_props "$props" "$iso_size")
    printf 'UDEV:%s\n' "$verdict" >> "$LOG" 2>/dev/null || true
    enforce_log_bound
    # NONE can mean empty tray OR udev has not settled; only trust YES/NO/TOO_SMALL here.
    if [[ "$verdict" == "BLANK:YES" || "$verdict" == "BLANK:NO" || "$verdict" == "BLANK:TOO_SMALL" ]]; then
      echo "$verdict"
      return 0
    fi
  fi

  local info
  info=$(capture_limited "$TIMEOUT_MEDIAINFO" dvd+rw-mediainfo "$dev" || true)
  printf '%s\n' "$info" >> "$LOG" 2>/dev/null || true
  enforce_log_bound
  classify_blank "$info" "$iso_size"
}

burn() {
  local iso="${1:-}"
  local dev="${2:-}"
  dev=$(resolve_dev "$dev" || true)
  if [[ $# -lt 2 && -n "$dev" ]]; then
    set -- "$iso" "$dev"
  fi
  maybe_newgrp_wrap "$dev" "$@"
  ensure_session "$@"
  iso="$1"
  dev="${2:-}"
  [[ -n "$dev" ]] || dev=$(resolve_dev "" || true)
  if [[ ! -f "$iso" || -L "$iso" ]]; then
    fail "iso-not-found"
    return 1
  fi
  if ! iso_is_safe_output "$iso"; then
    fail "iso-unsafe-path"
    return 1
  fi
  if [[ -z "$dev" ]]; then
    fail "no-dvd-drive"
    return 1
  fi
  dev=$(require_optical_dev "$dev") || {
    fail "invalid-device"
    return 1
  }
  local iso_fp dev_ident
  iso_fp=$(iso_fingerprint "$iso") || {
    fail "iso-unsafe-path"
    return 1
  }
  dev_ident=$(optical_dev_identity "$dev") || {
    fail "invalid-device"
    return 1
  }
  setup_job_traps
  {
    echo "=== video-to-dvd burn $(date -Iseconds) ==="
    echo "iso=$iso"
    echo "dev=$dev"
    echo "pgid=$$"
  } >> "$LOG"
  enforce_log_bound
  set +e
  set +o pipefail
  echo "PROGRESS:BURN:start"
  # QML Process has no TTY; USB trays also need a beat after the blank probe.
  udevadm settle --timeout=5 >/dev/null 2>&1 || true
  sleep 2
  # Re-check identity immediately before growisofs.
  dev=$(require_optical_dev "$dev" "$dev_ident")
  if [[ -z "$dev" ]]; then
    rm -f "$PGID_FILE"
    fail "invalid-device"
    return 1
  fi
  local burn_log rc
  burn_log=$(mktemp -- "$RUNTIME_DIR/burn.XXXXXX")
  safe_create_file "$burn_log" || true
  run_deadline "$TIMEOUT_GROWISOFS" growisofs -use-the-force-luke=tty -dvd-compat -Z "$dev"="$iso" 2>&1 \
    | pipe_log | retain_limited "$burn_log" "$MAX_CAPTURE_BYTES" | burn_progress_lines
  rc=${PIPESTATUS[0]}
  if [[ -f "$burn_log" && ! -L "$burn_log" ]] && grep -qiE 'no media mounted|cannot .*device|unable to open' "$burn_log"; then
    rc=1
  fi
  rm -f -- "$burn_log"
  set -e
  set -o pipefail
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    rm -f "$PGID_FILE"
    fail "timeout"
    return 1
  fi
  if [[ $rc -ne 0 ]]; then
    rm -f "$PGID_FILE"
    fail "burn-failed"
    return 1
  fi
  try_eject "$dev" || true
  # ISO is disposable after a successful burn. Revalidate before unlink.
  safe_unlink_iso "$iso" "$iso_fp" || true
  rm -f "$PGID_FILE"
  play_event_sound complete || true
  echo "RESULT:BURNED:$iso"
}

pkg_missing_list() {
  local missing=()
  if ! command -v ffmpeg >/dev/null 2>&1 && ! pacman -Q ffmpeg &>/dev/null; then
    missing+=("ffmpeg")
  fi
  if ! command -v dvdauthor >/dev/null 2>&1 && ! pacman -Q dvdauthor &>/dev/null; then
    missing+=("dvdauthor")
  fi
  if ! command -v genisoimage >/dev/null 2>&1 && ! command -v mkisofs >/dev/null 2>&1 && ! pacman -Q cdrtools &>/dev/null; then
    missing+=("cdrtools")
  fi
  if ! command -v growisofs >/dev/null 2>&1 && ! pacman -Q dvd+rw-tools &>/dev/null; then
    missing+=("dvd+rw-tools")
  fi
  if ! command -v bc >/dev/null 2>&1 && ! pacman -Q bc &>/dev/null; then
    missing+=("bc")
  fi
  if ! command -v eject >/dev/null 2>&1 && ! pacman -Q util-linux &>/dev/null; then
    missing+=("util-linux")
  fi
  local IFS=,
  echo "${missing[*]}"
}

drive_access_status() {
  local n=0 first="" line path
  while IFS= read -r line; do
    [[ "$line" == DEV:* ]] || continue
    n=$((n + 1))
    if [[ -z "$first" ]]; then
      path="${line#DEV:}"
      first="${path%%|*}"
    fi
  done < <(list_optical_drives)
  if (( n == 0 )); then
    printf '%s\n' "none"
    return 0
  fi
  # Writable via ACL/group, or account is already a member (newgrp wrap).
  if drive_is_writable "$first" || in_optical_group; then
    printf '%s\n' "ok"
    return 0
  fi
  printf '%s\n' "need-permission"
}

check_setup() {
  echo "MISSING:$(pkg_missing_list)"
  list_optical_drives
  echo "DRIVE:$(drive_access_status)"
}

list_drives() {
  list_optical_drives
}

# Same floating terminal as omarchy-launch-floating-terminal-with-presentation
# (org.omarchy.terminal + logo/done). Skip setsid so this process waits until
# the terminal closes and QML can re-probe.
launch_setup_terminal() {
  local cmd="$1"
  local presentation_script="omarchy-show-logo; ${cmd}; if (( \$? != 130 )); then omarchy-show-done; fi"
  echo "SETUP:CMD:${cmd}"
  if [[ "${VIDEO_TO_DVD_DRY_RUN:-}" == "1" ]]; then
    printf 'DRY-RUN: xdg-terminal-exec --app-id=org.omarchy.terminal --title=Omarchy -e bash -c %q\n' "$presentation_script"
    return 0
  fi
  xdg-terminal-exec --app-id=org.omarchy.terminal --title=Omarchy -e bash -c "$presentation_script"
}

install_packages() {
  local missing pkgs
  missing=$(pkg_missing_list)
  if [[ -z "$missing" ]]; then
    echo "SETUP:OK:packages-present"
    return 0
  fi
  pkgs=${missing//,/ }
  echo "SETUP:INSTALLING:${pkgs}"
  launch_setup_terminal "echo 'Installing packages...'; omarchy-pkg-add ${pkgs}"
  echo "SETUP:DONE"
}

add_optical() {
  local user="${USER:-$(id -un)}"
  local dev
  if [[ ! "$user" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "RESULT:ERROR:invalid-user"
    return 1
  fi
  dev=$(first_dvd_dev || true)
  if drive_is_writable "$dev" || in_optical_group; then
    echo "SETUP:OK:drive-ready"
    return 0
  fi
  echo "SETUP:DRIVE:${user}"
  launch_setup_terminal "echo 'Allowing this account to use the DVD drive...'; sudo usermod -aG optical ${user}"
  echo "SETUP:DONE"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  MODE="$1"; shift
  case "$MODE" in
    convert) convert "$@" ;;
    check-blank) check_blank "$@" ;;
    burn) burn "$@" ;;
    notify) notify_user "$@" ;;
    eject) eject_disc "$@" ;;
    check-setup|deps) check_setup ;;
    list-drives) list_drives ;;
    space-check) space_check "$@" ;;
    install-packages) install_packages ;;
    add-optical) add_optical ;;
    *) echo "Unknown mode: $MODE" >&2; exit 1 ;;
  esac
fi
