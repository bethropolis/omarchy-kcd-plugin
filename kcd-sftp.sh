#!/usr/bin/env bash

# io.github.bethropolis.kcd: mount or unmount a paired phone's storage over
# SFTP. Usage: kcd-sftp.sh <mount|unmount> <device-id>
#
# The panel spawns this detached, so an unhandled error would vanish. kcd
# does the real work for a mount (credential wait, sshfs, file-manager
# hand-off); this script's job is to turn a failure into something the user
# can act on.
#
#   mount succeeded      -> silent, the file manager opened
#   fuse not permitted   -> critical note with the /etc/fuse.conf fix
#   sshfs missing        -> critical note with the install command
#   unmount when unmounted -> critical note saying there was nothing mounted
#   stale mount          -> critical note naming the path that is stuck
#   anything else        -> critical note with kcd's own output
#
# Nothing here escalates privileges: fixes are printed for the user to run,
# never executed. The device id arrives as an argument and is only ever
# passed to kcd as one, so no shell interpolation of remote data happens.
#
# Mount is idempotent upstream (a repeat call returns the existing mount
# point), so there is no "already mounted" case to classify here.

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

# Folder glyph, matching the tile that triggers a mount; the tile shows an
# eject glyph when unmounting, so the two modes read as a pair.
GLYPH=$'\U000F07B'

if [[ $mode == unmount ]]; then
  if error=$(kcd sftp unmount "$device_id" 2>&1); then
    exit 0
  fi
  # kcd distinguishes these itself, so no guessing: "not mounted: no SFTP
  # mount for device <id>" and "stale SFTP mount at <path> could not be
  # released, ...".
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
