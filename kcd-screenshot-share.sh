#!/usr/bin/env bash

# Capture the focused monitor and send it to a paired phone via kcd share.
# Usage: kcd-screenshot-share.sh <device-id> <device-name>

# The panel already closed (grim must not catch it); the phone pulls
# seconds after `kcd share` returns, so captures stage as real temp files.

set -u

if (($# < 2)); then
  echo "Usage: kcd-screenshot-share.sh <device-id> <device-name>" >&2
  exit 1
fi

device_id="$1"
device_name="$2"

# Same send glyph Tailscale's notifier uses, so shares read as one family.
SEND_GLYPH=$'\U000F048A'

shot=$(mktemp /tmp/kcd-shot-XXXXXX.png) || {
  omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not capture screenshot" "temp file not writable"
  exit 1
}
# Backstop: staged captures older than an hour; a late phone may still pull.
find /tmp -maxdepth 1 -name 'kcd-shot-*.png' -mmin +59 -delete 2>/dev/null || true

# shot_base names the staged file on the wire and in the share.complete match.
shot_base=$(basename "$shot")

notify_fail() {
  omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not share with $device_name" "$1"
}

# Let the panel finish hiding so it is not in the frame.
sleep 0.5

# Focused monitor when hyprctl knows one, else grim's default output.
output=""
if command -v hyprctl >/dev/null 2>&1; then
  output=$(hyprctl monitors -j 2>/dev/null | python3 -c \
    'import json,sys; ms=json.load(sys.stdin); print(next((m["name"] for m in ms if m.get("focused")), ""))' \
    2>/dev/null || true)
fi

if [[ -n $output ]]; then
  grim_error=$(grim -o "$output" "$shot" 2>&1) || {
    notify_fail "${grim_error:-grim failed}"
    exit 1
  }
else
  grim_error=$(grim "$shot" 2>&1) || {
    notify_fail "${grim_error:-grim failed}"
    exit 1
  }
fi

if error=$(kcd share "$device_id" "$shot" 2>&1); then
  : # invitation sent; completion arrives below as share.complete
else
  notify_fail "${error:-Share request failed}"
  rm -f "$shot"
  exit 1
fi

# Wait for this file's terminal event. Timeout leaves the staged file for
# pruning so a late phone can still pull.
timeout 90 kcd watch --json '["share.complete"]' 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if not isinstance(ev, dict) or ev.get("type") != "share.complete":
        continue
    payload = ev.get("payload") or {}
    if payload.get("file") != want:
        continue
    sys.exit(0 if payload.get("success") else 1)
sys.exit(2)
' "$shot_base"
status=$?

if ((status == 0)); then
  rm -f "$shot"
  omarchy-notification-send -g "$SEND_GLYPH" "Shared with $device_name" "$shot_base"
elif ((status == 1)); then
  rm -f "$shot"
  notify_fail "$shot_base was rejected by the phone"
else
  omarchy-notification-send -g "$SEND_GLYPH" "Sharing with $device_name…" "$shot_base (sending in background)"
fi
