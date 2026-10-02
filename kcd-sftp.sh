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
#   already mounted      -> critical note with the unmount command
#   unmount never made   -> critical note saying nothing was mounted
#   anything else        -> critical note with kcd's own output
#
# Nothing here escalates privileges: fixes are printed for the user to run,
# never executed. The device id arrives as an argument and is only ever
# passed to kcd as one, so no shell interpolation of remote data happens.

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
  omarchy-notification-send -g "$GLYPH" -u critical "Could not unmount phone storage" \
    "${error:-kcd sftp unmount failed}"
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
elif [[ $output == *"already mounted"* || $output == *"Transport endpoint is not connected"* ]]; then
  hint="Already mounted, or an earlier mount went stale. Run: kcd sftp unmount $device_id"
elif [[ $output == *"errorMessage"* || $output == *"storage permission"* ]]; then
  hint="Grant storage permission on the phone, then try again."
else
  hint="${output:-kcd sftp mount failed}"
fi

omarchy-notification-send -g "$GLYPH" -u critical "Could not mount phone storage" "$hint"
exit "$status"
