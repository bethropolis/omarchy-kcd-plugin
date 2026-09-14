#!/usr/bin/env bash

# bet.kcd: capture the focused monitor and send it to a paired phone via kcd share.
# Usage: kcd-screenshot-share.sh <device-id> <device-name>
#
# The panel closes itself before this runs (grim must not catch it), so
# all feedback goes out as desktop notifications:
#   captured + sent -> "Shared with <name>"
#   grim failed     -> critical "screenshot failed" note
#   kcd share failed -> critical note with kcd's stderr
# The /tmp capture is always removed, never kept.

set -u

if (($# < 2)); then
  echo "Usage: kcd-screenshot-share.sh <device-id> <device-name>" >&2
  exit 1
fi

device_id="$1"
device_name="$2"

# Same send glyph Tailscale's notifier uses, so shares read as one family.
SEND_GLYPH=$'\U000F048A'

shot="/tmp/kcd-shot-$(date +'%Y-%m-%d_%H-%M-%S').png"
cleanup() { rm -f "$shot"; }
trap cleanup EXIT

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
    omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not capture screenshot" "${grim_error:-grim failed}"
    exit 1
  }
else
  grim_error=$(grim "$shot" 2>&1) || {
    omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not capture screenshot" "${grim_error:-grim failed}"
    exit 1
  }
fi

if error=$(kcd share "$device_id" "$shot" 2>&1); then
  omarchy-notification-send -g "$SEND_GLYPH" "Shared with $device_name" "$(basename "$shot")"
else
  omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not share with $device_name" "${error:-Share request failed}"
  exit 1
fi
