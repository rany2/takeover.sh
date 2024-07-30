#!/bin/sh
# vim: set ts=4 sw=4:
#---help---
# Usage: stage2.sh
#
# Environment Variables:
#   TO: The path to the target directory. Required.
#   SSH_PORT: The port number for the secondary SSH server. Required.
#   SSH_PASSWORD: The new password for the root account. Required.
#---help---
set -eu

# Define a function to print an error message and exit
die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "${@}" >&2  # bold red
	exit 1
}

# Ensure that this script is run from takeover.sh
[ "${__RUN_FROM_TAKEOVER_SH:-}" = "1" ] || \
	die "This script must not be executed directly! Use takeover.sh."

# Parse arguments
TO=${TO:?}
SSH_PORT=${SSH_PORT:?}
SSH_PASSWORD=${SSH_PASSWORD:?}

# Change to the target directory
cd "${TO}"

# Setup helper variables and functions
BUSYBOX="./bin/busybox.static"
${BUSYBOX} cat > busybox.einfo <<EOF
${BUSYBOX} printf '\n\033[1;36m> %s\033[0m\n' "\${*}" >&2  # bold cyan
EOF
${BUSYBOX} cat > busybox.die_msg <<EOF
${BUSYBOX} printf '\033[1;31mERROR:\033[0m %s\n' "\${*}" >&2  # bold red
EOF
DIE_MSG="${BUSYBOX} sh ./busybox.die_msg"
EINFO="${BUSYBOX} sh ./busybox.einfo"
CLEANUP_PATHS="busybox.einfo busybox.die_msg"
${BUSYBOX} chmod +x busybox.einfo busybox.die_msg

# Get the path to the current init
OLD_INIT=$(${BUSYBOX} readlink /proc/1/exe)

# Change the root password for the chroot environment
${BUSYBOX} chroot . /usr/bin/passwd root > /dev/null 2>&1 <<EOF
${SSH_PASSWORD}
${SSH_PASSWORD}
EOF

# Set up the target filesystem
${EINFO} "Setting up target filesystem..."
${BUSYBOX} rm -f etc/mtab
${BUSYBOX} ln -s /proc/mounts etc/mtab
${BUSYBOX} install -D -m 644 /etc/resolv.conf etc/resolv.conf
${BUSYBOX} mkdir -p old_root

# Mount pseudo-filesystems
${EINFO} "Mounting pseudo-filesystems..."
${BUSYBOX} mount -t tmpfs tmp tmp
${BUSYBOX} mount -t proc proc proc
${BUSYBOX} mount -t sysfs sys sys
if ! ${BUSYBOX} mount -t devtmpfs dev dev; then
	${BUSYBOX} mount -t tmpfs dev dev
	${BUSYBOX} cp -a /dev/* dev/
	${BUSYBOX} rm -rf dev/pts
	${BUSYBOX} mkdir dev/pts
fi
${BUSYBOX} mount --bind /dev/pts dev/pts

# Get the current TTY
TTY="$(${BUSYBOX} tty)"

# Redirect stdin, stdout, and stderr to the TTY
${EINFO} "Checking and switching TTY..."
exec <"${TO}/${TTY}" >"${TO}/${TTY}" 2>"${TO}/${TTY}"

# Print a message and wait for user confirmation
${EINFO} "Type 'OK' to continue"
${BUSYBOX} printf "> "
read -r a
if [ "${a}" != "OK" ]; then
	exit 1
fi

# Prepare the new init script
${EINFO} "Preparing init..."
${BUSYBOX} cat >"tmp/${OLD_INIT##*/}" <<EOF
#!${TO}/${BUSYBOX} sh

exec <"${TO}/${TTY}" >"${TO}/${TTY}" 2>"${TO}/${TTY}"

cd "${TO}"

${EINFO} 'Pivoting root and removing old takeover directory...'
${BUSYBOX} mount --make-rprivate /
${BUSYBOX} pivot_root . old_root && ${BUSYBOX} rmdir /old_root${TO}
${EINFO} 'Closing all file descriptors except stdin, stdout, stderr...'
for fd in /proc/self/fd/*; do
	fd=\${fd##*/}
	case "\${fd}" in
		[012]) continue ;;
	esac
	eval "exec \${fd}>&-"
done
${EINFO} 'Cleaning up and running new init...'
for path in ${CLEANUP_PATHS}; do
	${BUSYBOX} rm -f "\${path}"
done
exec ${BUSYBOX} sh -c "${BUSYBOX} rm -f '/tmp/${OLD_INIT##*/}' && exec /sbin/init"
EOF
${BUSYBOX} chmod +x "tmp/${OLD_INIT##*/}"

# Generate new SSH host keys
${EINFO} "Generating new SSH host keys..."
${BUSYBOX} chroot . /usr/bin/dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
${BUSYBOX} chroot . /usr/bin/dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key
${BUSYBOX} chroot . /usr/bin/dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key

# Start the secondary SSH server
${EINFO} "Starting secondary SSH server on port ${SSH_PORT}..."
${BUSYBOX} chroot . /usr/sbin/dropbear -p "${SSH_PORT}"

# Print the credentials for the secondary SSH server and wait for user confirmation
${EINFO} "You should SSH into the secondary sshd with the following credentials:
   - Port: ${SSH_PORT}
   - Username: root
   - Password: ${SSH_PASSWORD}
   - Command: ssh -p ${SSH_PORT} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@<IP>"
${EINFO} "Type 'OK' to continue"
${BUSYBOX} printf "> "
read -r a
if [ "${a}" != "OK" ]; then
	exit 1
fi

# Print a message to inform that the takeover is about to happen
# and the next steps to take after the takeover is successful
${EINFO} \
"About to take over init. This script will now pause for a few seconds.
> If the takeover was successful, you will see output from the new init.
> You may then kill the remnants of this session and any remaining
> processes from your new SSH session, and umount the old root filesystem."

# Bind mount old init binary to the new init
${BUSYBOX} mount --bind "tmp/${OLD_INIT##*/}" "${OLD_INIT}"

# Re-exec init to start the new init.
#
# NOTE: DO NOT use ${EINFO}, ${DIE_MSG}, or any other variables or
#       functions defined above after this point as they will not
#       will no longer be available beyond this point as it will
#       be removed by the new init.
if command -v systemctl > /dev/null 2>&1; then
	systemctl daemon-reexec
elif command -v telinit > /dev/null 2>&1; then
	telinit u
else
	${DIE_MSG} "Don't know how to re-exec init"
	exit 1
fi

# Unset trap handler as cleanup is no longer required
# as the takeover was completed successfully. This is
# technically not required as we call exec below, but
# it's better in case something changes in the future.
trap '' EXIT HUP INT TERM

# Sleep for a while to allow the new init to start
exec ${BUSYBOX} sleep 10
