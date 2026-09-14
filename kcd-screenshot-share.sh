#!/usr/bin/env bash

# bet.kcd: capture the focused monitor and send it to a paired phone via kcd share.
# Usage: kcd-screenshot-share.sh <device-id> <device-name>
#
# The panel closes itself before this runs (grim must not catch it), so
# all feedback goes out as desktop notifications.
#
# Race this avoids: `kcd share` returns once the transfer INVITATION is
# sent, but the daemon only opens the file seconds later when the phone
# connects to the side-channel. Deleting the capture on CLI return (e.g.
# a /tmp trap) makes the send fail with "no such file or directory".
# Captures therefore stage in the cache dir and are deleted only after a
# terminal share.complete event (or after 24h by the prune pass).

set -u

if (($# < 2)); then
  echo "Usage: kcd-screenshot-share.sh <device-id> <device-name>" >&2
  exit 1
fi

device_id="$1"
device_name="$2"

# Same send glyph Tailscale's notifier uses, so shares read as one family.
SEND_GLYPH=$'\U000F048A'

shot_dir="${XDG_CACHE_HOME:-$HOME/.cache}/bet.kcd/shots"
mkdir -p "$shot_dir" || {
  omarchy-notification-send -g "$SEND_GLYPH" -u critical "Could not capture screenshot" "cache dir not writable"
  exit 1
}
# Backstop: drop staged captures older than a day (kept that long so a
# late-connecting phone can still pull the file).
find "$shot_dir" -type f -mmin +1439 -delete 2>/dev/null || true

shot="$shot_dir/kcd-shot-$(date +'%Y-%m-%d_%H-%M-%S').png"
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

# Wait for the terminal event for THIS file (ack line + unrelated events
# skipped). Timeout leaves the staged file for the 24h prune pass so a
# late phone can still complete the pull.
result=$(timeout 90 kcd watch --json '["share.complete"]' 2>/dev/null | python3 -c '
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
' "$shot_base")
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
