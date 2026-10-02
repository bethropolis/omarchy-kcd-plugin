#!/usr/bin/env bash

# io.github.bethropolis.kcd: mount a paired phone's storage over SFTP and
# hand it to the file manager.
# Usage: kcd-sftp.sh <device-id>
#
# kcd does the whole job (credential wait, sshfs mount, xdg-open), so this
# script only turns its failure into something the user can act on. The
# panel spawns it detached, which means an unhandled error would vanish:
#
#   mounted                -> silent, the file manager opened
#   fuse not permitted     -> critical note with the /etc/fuse.conf fix
#   sshfs missing          -> critical note with the install command
#   already mounted/stale  -> critical note with the unmount command
#   anything else          -> critical note with kcd's own output
#
# Nothing here escalates privileges: fixes are printed for the user to run,
# never executed. The device id arrives as an argument and is only ever
# passed to kcd as one, so no shell interpolation of remote data happens.

set -u

if (($# < 1)); then
  echo "Usage: kcd-sftp.sh <device-id>" >&2
  exit 1
fi

device_id="$1"

# Folder glyph, matching the tile that triggers this.
MOUNT_GLYPH=$'\U000F07B'

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

omarchy-notification-send -g "$MOUNT_GLYPH" -u critical "Could not mount phone storage" "$hint"
exit "$status"
