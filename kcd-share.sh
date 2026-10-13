#!/usr/bin/env bash

# Pick one local file and send it to a paired phone via kcd share.
# Usage: kcd-share.sh <device-id> <device-name>

# The panel already closed, so outcomes report via desktop notifications.

set -u

if (($# < 2)); then
  echo "Usage: kcd-share.sh <device-id> <device-name>" >&2
  exit 1
fi

device_id="$1"
device_name="$2"

# Same send glyph as Tailscale's notifier.
SEND_GLYPH=$'\U000F048A'

picked=""
status=0
picked=$(omarchy-file-select --title "Share with $device_name") || status=$?

if ((status > 1)); then
  omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not share with $device_name" \
    "The file chooser did not open"
  exit 1
fi

# Cancelled is a decision, not a fault: stay silent.
[[ -n $picked ]] || exit 0

if [[ -d $picked ]]; then
  omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not share with $device_name" \
    "$(basename "$picked") is a folder — file sharing only"
  exit 1
fi

if error=$(kcd share "$device_id" "$picked" 2>&1); then
  omarchy-notification-send -g "$SEND_GLYPH" "Shared with $device_name" "$(basename "$picked")"
else
  omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not share with $device_name" "${error:-Share request failed}"
  exit 1
fi
