#!/bin/sh
# vim: set ts=4 sw=4:
#---help---
# Usage: stage1.sh [options] [--] <dest> [<script> [<script-opts...>]]
#
# This script creates Alpine Linux rootfs for containers. It must be run as
# root - to create files with correct permissions and use chroot (optional).
# If $APK is not available on the host system, then static apk-tools
# specified by $APK_TOOLS_URI is downloaded and used.
#
# Arguments:
#   <dest>                                Path where to write the rootfs.
#
#   <script>                              Path of script to execute after installing base system in
#                                         the prepared rootfs and before clean-up. Use "-" to read
#                                         the script from STDIN; if it doesn't start with a shebang,
#                                         "#!/bin/sh -e" is prepended.
#
#   <script-opts>                         Arguments to pass to the script.
#
# Options and Environment Variables:
#   -b --branch ALPINE_BRANCH             Alpine branch to install; used only when
#                                         --repositories-file is not specified. Default is
#                                         latest-stable.
#
#      --keys-dir KEYS_DIR                Path of directory with Alpine keys to copy into
#                                         the rootfs. Default is /etc/apk/keys. If does not exist,
#                                         keys specified in ALPINE_KEYS environment variable are used.
#
#   -m --mirror-uri ALPINE_MIRROR         URI of the Aports mirror to fetch packages; used only
#                                         when --repositories-file is not specified. Default is
#                                         http://dl-cdn.alpinelinux.org/alpine.
#
#   -C --no-cleanup (CLEANUP)             Don't umount and remove temporary directories when done.
#
#      --no-default-pkgs (DEFAULT_PKGS)   Don't install the default base packages (alpine-baselayout
#                                         busybox busybox-suid musl-utils), i.e. only the packages
#                                         specified in --packages will be installed. Use only if
#                                         you know what are you doing!
#
#   -p --packages PACKAGES                Additional packages to install into the rootfs.
#
#   -r --repositories-file REPOS_FILE     Path of repositories file to copy into the rootfs.
#                                         If not specified, a repositories file will be created with
#                                         Alpine's main and community repositories on --mirror-uri.
#
#   -c --script-chroot (SCRIPT_CHROOT)    Bind <script>'s directory (or CWD if read from STDIN) at
#                                         /mnt inside the rootfs dir and chroot into the rootfs
#                                         before executing <script>. Otherwise <script> is executed
#                                         in the current directory and $ROOTFS variable points to
#                                         the rootfs directory.
#
#   -d --temp-dir TEMP_DIR                Path where to create a temporary directory; used for
#                                         downloading apk-tools when not available on the host
#                                         sytem or for rootfs when <dest> is "-" (i.e. STDOUT).
#                                         This path must not exist! Defaults to using `mkdir -d`.
#
#   -h --help                             Show this help message and exit.
#
#   -v --version                          Print version and exit.
#
#   APK                                   APK command to use. Default is "apk".
#
#   APK_OPTS                              Options to pass into apk on each execution.
#                                         Default is "--no-progress".
#
#   APK_TOOLS_URI                         URL of apk-tools binary to download if $APK is not found
#                                         on the host system. Required.
#
#   APK_TOOLS_SHA256                      SHA-256 checksum of $APK_TOOLS_URI. Required.
#
#   ALPINE_KEYS                           List of Alpine keys to embed in the script. Each line
#                                         must be in the format "filename:content" with content
#                                         being the key in ASCII-armored format printf encoded.
#                                         Required.
#
# Each option can be also provided by environment variable. If both option and
# variable is specified and the option accepts only one argument, then the
# option takes precedence.
#
# Modified from https://github.com/alpinelinux/alpine-make-rootfs.
#---help---
set -eu

readonly PROGNAME='takeover.sh-stage1'
readonly VERSION='0.7.0-takeover.sh0.0.4'

# Base Alpine packages to install in rootfs.
readonly ALPINE_BASE_PKGS='alpine-baselayout busybox busybox-suid musl-utils'

# An opaque string used to detect changes in resolv.conf.
readonly RESOLVCONF_MARK="### created by ${PROGNAME} ###"
# Name used as a "virtual package" for temporarily installed packages.
readonly VIRTUAL_PKG=".make-${PROGNAME}"

# Define a function to print an error message and exit
die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "${@}" >&2  # bold red
	exit 1
}

# Ensure that this script is run from takeover.sh
[ "${__RUN_FROM_TAKEOVER_SH:-}" = "1" ] || \
	die "This script must not be executed directly! Use takeover.sh."

APK="${APK:-apk}"
APK_OPTS="${APK_OPTS:---no-progress}"
APK_TOOLS_URI="${APK_TOOLS_URI:?}"
APK_TOOLS_SHA256="${APK_TOOLS_SHA256:?}"
ALPINE_KEYS="${ALPINE_KEYS:?}"

# Set pipefail if supported.
if ( set -o pipefail 2>/dev/null ); then
	set -o pipefail
fi

# For compatibility with systems that does not have "realpath" command.
if ! command -v realpath >/dev/null; then
	alias realpath='readlink -f'
fi

einfo() {
	printf '\n\033[1;36m> %s\033[0m\n' "${@}" >&2  # bold cyan
}

# Prints help and exists with the specified status.
help() {
	sed -En '/^#---help---/,/^#---help---/p' "${0}" | sed -E 's/^# ?//; 1d;$d;'
	exit "${1:-0}"
}

# Cleans the host system. This function is executed before exiting the script.
cleanup() {
	set +eu
	trap '' EXIT HUP INT TERM  # unset trap to avoid loop

	if [ -d "${TEMP_DIR}" ]; then
		rm -Rf "${TEMP_DIR}"
	fi
	if [ -d "${rootfs}" ]; then
		umount_recursively "${rootfs}" \
			|| die "Failed to unmount mounts inside ${rootfs}!"
		[ "${rootfs}" = "${ROOTFS_DEST}" ] || rm -Rf "${rootfs}"
	fi
}

_apk() {
	"${APK}" ${APK_OPTS} "${@}"
}

# Writes Alpine APK keys embedded in this script into directory $1.
dump_alpine_keys() {
	dest_dir="${1}"

	mkdir -p "${dest_dir}"
	for line in ${ALPINE_KEYS}; do
		file=${line%%:*}
		content=${line#*:}

		printf -- "-----BEGIN PUBLIC KEY-----\n${content}\n-----END PUBLIC KEY-----\n" \
			> "${dest_dir}/${file}"
	done
}

# Binds the directory $1 at the mountpoint $2 and sets propagation to private.
mount_bind() {
	mkdir -p "${2}"
	mount --bind "${1}" "${2}"
	mount --make-private "${2}"
}

# Prepares chroot at the specified path.
prepare_chroot() {
	dest="${1}"

	mkdir -p "${dest}"/proc
	mount -t proc none "${dest}"/proc
	mount_bind /dev "${dest}"/dev
	mount_bind /sys "${dest}"/sys

	install -D -m 644 /etc/resolv.conf "${dest}"/etc/resolv.conf
	echo "${RESOLVCONF_MARK}" >> "${dest}"/etc/resolv.conf
}

# Unmounts all filesystems under the directory tree $1 (must be absolute path).
umount_recursively() {
	mount_point="$(realpath "${1}")"

	cut -d ' ' -f 2 /proc/mounts \
		| { grep "^${mount_point}/" || true; } \
		| sort -r \
		| xargs -r -n 1 umount
}

# Downloads the specified file using wget or curl and checks checksum.
wgets() (
	url="${1}"
	sha256="${2}"
	dest="${3:-.}"

	if command -v wget >/dev/null 2>&1; then
		cd "${dest}" \
			&& wget -T 10 --no-verbose "${url}" \
			&& echo "${sha256}  ${url##*/}" | sha256sum -c
	elif command -v curl >/dev/null 2>&1; then
		cd "${dest}" \
			&& curl --connect-timeout 10 -L -f -sS -O "${url}" \
			&& echo "${sha256}  ${url##*/}" | sha256sum -c
	else
		die 'Neither wget nor curl found!'
	fi

)

# Writes STDIN into file $1 and sets it executable bit. If the content does not
# start with a shebang, prepends "#!/bin/sh -e" before the first line.
write_script() {
	filename="${1}"

	cat > "${filename}.tmp"

	if ! grep -q -m 1 '^#!' "${filename}.tmp"; then
		echo "#!/bin/sh -e" > "${filename}"
	fi

	cat "${filename}.tmp" >> "${filename}"
	rm "${filename}.tmp"

	chmod +x "${filename}"
}


#=============================  M a i n  ==============================#

opts=$(getopt -n "${PROGNAME}" -o b:m:Cp:r:s:cd:t:hV \
	-l branch:,fs-skel-chown:,fs-skel-dir:,keys-dir:,mirror-uri:,no-cleanup,no-default-pkgs,packages:,repositories-file:,script-chroot,temp-dir:,help,version \
	-- "${@}") || help 1 >&2

eval set -- "${opts}"
while [ ${#} -gt 0 ]; do
	n=2
	case "${1}" in
		-b | --branch) ALPINE_BRANCH="${2}";;
		     --keys-dir) KEYS_DIR="${2}";;
		-m | --mirror-uri) ALPINE_MIRROR="${2}";;
		-C | --no-cleanup) CLEANUP='no'; n=1;;
		     --no-default-pkgs) DEFAULT_PKGS='no'; n=1;;
		-p | --packages) PACKAGES="${PACKAGES:-} ${2}";;
		-r | --repositories-file) REPOS_FILE="${2}";;
		-c | --script-chroot) SCRIPT_CHROOT='yes'; n=1;;
		-d | --temp-dir) TEMP_DIR="${2}";;
		-h | --help) help 0;;
		-V | --version) echo "${PROGNAME} ${VERSION}"; exit 0;;
		--) shift; break;;
	esac
	shift "${n}"
done

[ ${#} -ne 0 ] || help 1 >&2

ROOTFS_DEST="${1}"; shift
SCRIPT=
[ ${#} -eq 0 ] || { SCRIPT="${1}"; shift; }

[ "$(id -u)" -eq 0 ] || die 'This script must be run as root!'
[ ! -e "${TEMP_DIR:-}" ] || die "Temp path ${TEMP_DIR} must not exist!"

ALPINE_BRANCH="${ALPINE_BRANCH:="latest-stable"}"
ALPINE_MIRROR="${ALPINE_MIRROR:="https://dl-cdn.alpinelinux.org/alpine"}"
CLEANUP="${CLEANUP:="yes"}"
DEFAULT_PKGS="${DEFAULT_PKGS:="yes"}"
KEYS_DIR="${KEYS_DIR:-/etc/apk/keys}"
PACKAGES="${PACKAGES:-}"
REPOS_FILE="${REPOS_FILE:-}"
SCRIPT_CHROOT="${SCRIPT_CHROOT:="no"}"
TEMP_DIR="${TEMP_DIR:-$(mktemp -d /tmp/"${PROGNAME}".XXXXXX)}"

case "${ALPINE_BRANCH}" in
	[0-9]*) ALPINE_BRANCH="v${ALPINE_BRANCH}";;
esac

[ -n "${PACKAGES}" ] || [ "${DEFAULT_PKGS}" = 'yes' ] || \
	die 'No packages specified to be installed!'

rootfs="${ROOTFS_DEST}"
script_file="${SCRIPT}"
if [ "${SCRIPT}" = '-' ]; then
	script_file="${TEMP_DIR}/.setup.sh"
	write_script "${script_file}"
fi
if [ -n "${script_file}" ]; then
	script_file=$(realpath "${script_file}")
fi

[ "${CLEANUP}" = no ] || trap cleanup EXIT HUP INT TERM

#-----------------------------------------------------------------------
if ! command -v "${APK}" >/dev/null; then
	einfo "${APK} not found, downloading static apk-tools"

	wgets "${APK_TOOLS_URI}" "${APK_TOOLS_SHA256}" "${TEMP_DIR}"
	APK="${TEMP_DIR}/apk.static"
	chmod +x "${APK}"
fi

#-----------------------------------------------------------------------
einfo 'Installing system'

mkdir -p "${rootfs}"/etc/apk/keys

if [ -f "${REPOS_FILE}" ]; then
	install -m 644 "${REPOS_FILE}" "${rootfs}"/etc/apk/repositories
else
	cat > "${rootfs}"/etc/apk/repositories <<-EOF
		${ALPINE_MIRROR}/${ALPINE_BRANCH}/main
		${ALPINE_MIRROR}/${ALPINE_BRANCH}/community
	EOF
fi

if [ -d "${KEYS_DIR}" ]; then
	cp "${KEYS_DIR}"/* "${rootfs}"/etc/apk/keys/
else
	dump_alpine_keys "${rootfs}"/etc/apk/keys/
fi

if [ "${DEFAULT_PKGS}" = 'yes' ]; then
	_apk add --root "${rootfs}" --initdb ${ALPINE_BASE_PKGS} >&2
fi
_apk add --root "${rootfs}" --initdb ${PACKAGES} >&2

if ! [ -f "${rootfs}"/etc/alpine-release ]; then
	if _apk info --root "${rootfs}" --quiet alpine-release >/dev/null; then
		_apk add --root "${rootfs}" alpine-release
	else
		# In Alpine <3.17, this package contains /etc/os-release,
		# /etc/alpine-release and /etc/issue, but we don't wanna install all
		# its dependencies (e.g. openrc).
		_apk fetch --root "${rootfs}" --stdout alpine-base \
			| tar -xz -C "${rootfs}" etc >&2
	fi
fi

# Disable root log in without password.
sed -i 's/^root::/root:*:/' "${rootfs}"/etc/shadow

[ -e "${rootfs}"/var/run ] || ln -s /run "${rootfs}"/var/run

#-----------------------------------------------------------------------
if [ -n "${SCRIPT}" ]; then
	script_name="${script_file##*/}"

	if [ "${SCRIPT_CHROOT}" = 'no' ]; then
		einfo "Executing script: ${script_name} $*"

		ROOTFS="${rootfs}" "${script_file}" "$@" >&2 || die 'Script failed'
	else
		einfo 'Preparing chroot'

		_apk add --root "${rootfs}" -t "${VIRTUAL_PKG}" apk-tools >&2
		prepare_chroot "${rootfs}"

		if [ "${SCRIPT}" = '-' ]; then
			cp "${script_file}" "${rootfs}/${script_name}"
			bind_dir="$(pwd)"
			script_file2="/${script_name}"
		else
			bind_dir="$(dirname "${script_file}")"
			script_file2="./${script_name}"
		fi
		echo "Mounting ${bind_dir} to /mnt inside chroot" >&2
		mount_bind "${bind_dir}" "${rootfs}"/mnt

		einfo "Executing script in chroot: ${script_name} $*"

		chroot "${rootfs}" \
			/bin/sh -c "cd /mnt && ${script_file2} \"\$@\"" -- "$@" >&2 \
			|| die 'Script failed'

		[ "${SCRIPT}" = '-' ] && rm -f "${rootfs}/${script_name}"
		umount_recursively "${rootfs}"
	fi
fi

#-----------------------------------------------------------------------
einfo 'Cleaning-up rootfs'

if _apk info --root "${rootfs}" --quiet --installed "${VIRTUAL_PKG}"; then
	_apk del --root "${rootfs}" --purge "${VIRTUAL_PKG}" >&2
fi

if grep -qw "${RESOLVCONF_MARK}" "${rootfs}"/etc/resolv.conf 2>/dev/null; then
	rm "${rootfs}"/etc/resolv.conf
fi

rm -Rf "${rootfs:?}"/dev/*

if [ -f "${rootfs}"/sbin/apk ]; then
	rm -Rf "${rootfs}"/var/cache/apk/*
else
	rm -Rf "${rootfs}"/etc/apk "${rootfs}"/lib/apk "${rootfs}"/var/cache/apk
fi
