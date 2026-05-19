#!/usr/bin/env bash
# Stream the device's [player_core] / [raw-media_kit] / mpv log lines from
# logcat in real time. Run in a separate terminal while a Maestro flow
# or the example app is in use.
#
# Usage:
#   ./tail_logs.sh                    # stream live
#   ./tail_logs.sh --since '11:08'    # stream from a given clock time
#   ./tail_logs.sh --once             # dump the last 200 lines and exit
#
# Requires `adb` on PATH and a device connected. Auto-detects the first
# attached device; override with $DEVICE.

set -euo pipefail

ADB="${ADB:-adb}"
DEVICE="${DEVICE:-$($ADB devices | awk '/device$/{print $1; exit}')}"

if [[ -z "$DEVICE" ]]; then
  echo "No device attached. Plug in your phone and re-run." >&2
  exit 1
fi

# Tags we care about, in priority order:
#   flutter  — all debugPrint output, including [player_core] / [raw-media_kit]
#   mpv      — direct libmpv log lines (if mpv-build was made with verbose)
#   AudioService — audio_service plugin lifecycle
FILTER='flutter:V mpv:V AudioService:I *:S'

if [[ "${1:-}" == "--once" ]]; then
  exec "$ADB" -s "$DEVICE" logcat -d -t 200 -v time $FILTER
fi

if [[ "${1:-}" == "--since" ]]; then
  shift
  exec "$ADB" -s "$DEVICE" logcat -T "${1}.000" -v time $FILTER
fi

echo "Streaming from $DEVICE — Ctrl+C to stop." >&2
exec "$ADB" -s "$DEVICE" logcat -v time $FILTER
