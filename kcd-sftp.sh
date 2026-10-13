#!/usr/bin/env bash

# Mount or unmount a paired phone's storage over SFTP.
# Usage: kcd-sftp.sh <mount|unmount> <device-id>

# Detached spawn, so failures report as actionable notifications (never
# silent); fixes are printed for the user, never executed.

# Mount is idempotent upstream: no "already mounted" case to classify.

set -u

if (($# < 2)); then
  echo "Usage: kcd-sftp.sh <mount|unmount> <device-id>" >&2
  exit 1
fi

mode="$1"
device_id="$2"

case $mode in
  mount | unmount) ;;
  *)
    echo "Usage: kcd-sftp.sh <mount|unmount> <device-id>" >&2
    exit 1
    ;;
esac

# Folder glyph matches the mount tile; eject when unmounting.
GLYPH=$'\U000F07B'

if [[ $mode == unmount ]]; then
  if error=$(kcd sftp unmount "$device_id" 2>&1); then
    exit 0
  fi
  # kcd distinguishes these itself, so match its messages, don't guess.
  case $error in
    "not mounted"*)
      hint="There was nothing mounted to unmount. Mount it first with the Files tile."
      ;;
    "stale SFTP mount"*)
      hint="${error} — unmount it by hand: fusermount3 -u <the path above>"
      ;;
    *)
      hint="${error:-kcd sftp unmount failed}"
      ;;
  esac
  omarchy-notification-send -g "$GLYPH" -u critical "Could not unmount phone storage" "$hint"
  exit 1
fi

output=$(kcd sftp mount "$device_id" 2>&1)
status=$?

if ((status == 0)); then
  exit 0
fi

# Ordered most-specific first: the first match wins.
if [[ $output == *user_allow_other* ]]; then
  hint="FUSE needs user_allow_other in /etc/fuse.conf. Run: sudo sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf"
elif [[ $output == *"sshfs: not found"* || $output == *"executable file not found"* ]]; then
  hint="sshfs is not installed. Run: sudo pacman -S sshfs"
elif [[ $output == *"errorMessage"* || $output == *"storage permission"* ]]; then
  hint="Grant storage permission on the phone, then try again."
else
  hint="${output:-kcd sftp mount failed}"
fi

omarchy-notification-send -g "$GLYPH" -u critical "Could not mount phone storage" "$hint"
exit "$status"
