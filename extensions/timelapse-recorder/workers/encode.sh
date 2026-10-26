#!/bin/sh
# 不使用 eval，避免将可执行文件和路径作为 Shell 语法解释。
set -eu
job=$1
cd "$job"
terminal=0
status() {
  printf '%s\n' "$1" > "$job/status.next"
  mv -f "$job/status.next" "$job/status"
  case "$1" in ready|done|failed|cancelled) terminal=1 ;; esac
}
pid=
on_exit() {
  if [ "$terminal" -eq 0 ]; then
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
    status failed || true
  fi
}
trap on_exit EXIT
cancel_child() {
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  status cancelled
  exit 0
}
trap cancel_child HUP INT TERM
status probing
IFS= read -r ffmpeg < "$job/ffmpeg.txt"
IFS= read -r mode < "$job/mode.txt"
if [ -f "$job/cancel" ]; then cancel_child; fi
if ! "$ffmpeg" -version > "$job/probe.log" 2>&1; then status failed; exit 0; fi
if ! "$ffmpeg" -hide_banner -encoders >> "$job/probe.log" 2>&1; then status failed; exit 0; fi
if ! grep -Eq '(^|[[:space:]])libx264([[:space:]]|$)' "$job/probe.log"; then
  printf '%s\n' 'FFmpeg needs the libx264 encoder.' >> "$job/probe.log"
  status failed; exit 0
fi
if [ "$mode" = probe ]; then status ready; exit 0; fi
IFS= read -r fps < "$job/fps.txt"
IFS= read -r scale < "$job/scale.txt"
IFS= read -r hold < "$job/hold.txt"
IFS= read -r background < "$job/background.txt"
status encoding
"$ffmpeg" -hide_banner -loglevel error -nostdin -y -framerate "$fps" -start_number 1 \
  -i 'frame-%08d.png' \
  -vf "scale=iw*$scale:ih*$scale:flags=neighbor,pad=ceil(iw/2)*2:ceil(ih/2)*2:0:0:color=0x$background,tpad=stop_mode=clone:stop_duration=$hold" \
  -an -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart \
  -progress "$job/progress.txt" -nostats "$job/encoded.mp4" > "$job/stdout.log" 2> "$job/stderr.log" &
pid=$!
while kill -0 "$pid" 2>/dev/null; do
  if [ -f "$job/cancel" ]; then cancel_child; fi
  sleep 0.1
done
if wait "$pid"; then
  if [ -f "$job/cancel" ]; then status cancelled; else status 'done'; fi
else
  if [ -f "$job/cancel" ]; then status cancelled; else status failed; fi
fi
