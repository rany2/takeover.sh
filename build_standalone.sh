#!/usr/bin/env bash

einfo() {
    printf '\n\033[1;36m> %s\033[0m\n' "${*}" >&2  # bold cyan
}

die() {
    printf '\033[1;31mERROR:\033[0m %s\n' "${*}" >&2  # bold red
    exit 1
}

set -eu
trap 'die "An unexpected error occurred!"' ERR
step=1 # Used for backup file names

einfo "Building standalone takeover script..."

einfo "Copying the original script..."
cp src/takeover.sh takeover.sh

einfo "Removing the lines between the markers..."
sed '/^#---remove-if-standalone---$/,/^#---remove-if-standalone---$/d' -i.orig.$((step++)) takeover.sh

einfo "Adding the base64 dependency check..."
sed 's|^#---add-base64-dep-check-if-standalone---$|dep_check_strict "base64"|' -i.orig.$((step++)) takeover.sh

einfo "Adding the base64 encoded stage1 and stage2 scripts..."
stage1_b64=$(base64 -w0 src/stage1.sh)
stage2_b64=$(base64 -w0 src/stage2.sh)

einfo "Embedding stage1 and stage2 scripts into the takeover script..."
sed "s|/bin/sh ./stage1.sh|printf '%s' '""${stage1_b64}""' \| base64 -d \| /bin/sh -s --|" -i.orig.$((step++)) takeover.sh
sed "s|/bin/sh ./stage2.sh|/bin/sh -c \"\$\(printf '%s' '""${stage2_b64}""' \| base64 -d\)\"|" -i.orig.$((step++)) takeover.sh

einfo "Setting the correct permissions..."
chmod +x takeover.sh

einfo "Removing the backup files..."
rm -f takeover.sh.orig.*

einfo "Done!"
