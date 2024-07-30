#!/bin/sh
# vim: set ts=4 sw=4:
#---help---
# Usage: takeover.sh [OPTIONS]
#
# This script will create an Alpine Linux rootfs in a tmpfs and pivot into it.
#
# Options:
#   -b, --branch BRANCH      The Alpine Linux branch to use. Default: latest-stable
#
#   -p, --packages PKGS      Additional packages to install. Default: btrfs-progs btrfs-progs-extra dosfstools e2fsprogs e2fsprogs-extra xfsprogs lsof umount tar gzip bzip2 xz htop nano
#
#   -t, --tmpfs-options OPTS Additional options for the tmpfs mount. Default: mode=0755
#
#   -P, --ssh-port PORT      The port to start the secondary sshd on. Default: 2222
#
#   -h, --help               Show this help message and exit.
#
#   -v, --version            Print version and exit.
#
# https://github.com/rany2/takeover.sh
#---help---

# Default user options.
ALPINE_BRANCH=latest-stable
PACKAGES="btrfs-progs btrfs-progs-extra dosfstools e2fsprogs e2fsprogs-extra xfsprogs"
PACKAGES="${PACKAGES} lsof umount tar gzip bzip2 xz"
PACKAGES="${PACKAGES} htop nano"
TMPFS_OPTIONS="mode=0755"
SSH_PORT=2222

# Exit on error and unset variable to catch issues early.
set -eu

readonly PROGNAME='takeover.sh'
readonly VERSION='0.0.4'

# Set pipefail if supported.
if ( set -o pipefail 2>/dev/null ); then
	set -o pipefail
fi

die() {
	printf '\033[1;31mERROR:\033[0m %s\n' "$@" >&2  # bold red
	exit 1
}

# Cleans the host system. This function is executed before exiting the script.
cleanup() {
	set +eu
	trap '' EXIT HUP INT TERM  # unset trap to avoid loop

	if [ -n "${TO}" ] && [ -d "${TO}" ]; then
		umount "${TO}" 2>/dev/null || true
		rmdir "${TO}"
	fi

	exit 1
}

# Prints help and exists with the specified status.
help() {
	sed -En '/^#---help---/,/^#---help---/p' "${0}" | sed -E 's/^# ?//; 1d;$d;'
	exit "${1:-0}"
}

# Check if all dependencies are available.
dep_check_strict() {
	for dep in $1; do
		if ! command -v "${dep}" > /dev/null 2>&1; then
			die "Dependency not found: ${dep}"
		fi
	done
}

# Check if any of the dependencies are available.
dep_check_any() {
	for dep in $1; do
		if command -v "${dep}" > /dev/null 2>&1; then
			return
		fi
	done
	die "None of the following dependencies found: $1"
}

# Check if all dependencies are available.
dep_check_strict "umount rmdir sed getopt mktemp tr head uname mount /bin/sh"  # takeover.sh
dep_check_strict "getopt grep sed sha256sum tar"  # stage1.sh
#---add-base64-dep-check-if-standalone---
dep_check_any "wget curl"  # stage1.sh
dep_check_any "systemctl telinit"  # stage2.sh
#---remove-if-standalone---
for file in stage1.sh stage2.sh; do
	[ -f "${file}" ] || die "Required file not found: ${file}"
done
#---remove-if-standalone---

# Parse command line options.
opts=$(getopt -n "${PROGNAME}" -o b:p:t:P:hv \
	-l branch:,packages:,tmpfs-options:,ssh-port:,help,version \
	-- "${@}") || help 1 >&2

eval set -- "${opts}"
while [ ${#} -gt 0 ]; do
	n=2
	case "${1}" in
		-b | --branch) ALPINE_BRANCH="${2}" ;;
		-p | --packages) PACKAGES="${2}" ;;
		-t | --tmpfs-options) TMPFS_OPTIONS="${2}" ;;
		-P | --ssh-port) SSH_PORT="${2}" ;;
		-h | --help) help 0 ;;
		-v | --version) echo "${PROGNAME} ${VERSION}"; exit 0 ;;
		--) shift; break ;;
	esac
	shift "${n}"
done

# Required packages for the Alpine Linux rootfs. These cannot be altered
# as later stages depend on them, especially busybox-static and dropbear.
# apk-tools isn't strictly required, but it's useful to the user in case
# they want to install additional packages later. alpine-release provides
# the APK repository keys so it is a required package for apk-tools,
# though it does not depend on it for some reason.
PACKAGES="${PACKAGES} alpine-release apk-tools openrc"
PACKAGES="${PACKAGES} busybox-static"
PACKAGES="${PACKAGES} dropbear"

# Check if the script is being run as root. This should be done before
# creating the temporary directory as it would otherwise likely fail
# due to permission/ownership issues.
[ "$(id -u)" -eq 0 ] || die 'This script must be run as root!'

# Create a temporary directory that will be used as the rootfs.
TO=$(mktemp -d /takeover.XXXXXX)
trap cleanup EXIT HUP INT TERM

# Generate a random password for the secondary SSH server.
SSH_PASSWORD=$(tr -d -c 'A-Za-z0-9' </dev/urandom | head -c 10 || true)
[ -n "${SSH_PASSWORD}" ] || die "Failed to generate a random password for the secondary SSH server!"

# This is done in case APK is not available on the host.
ARCH=$(uname -m)
case "${ARCH}" in
	x86_64)
		APK_TOOLS_URI="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.4/x86_64/apk.static"
		APK_TOOLS_SHA256="42cea2a41dc09b263f04bb0ade8a2ba251256b91f89095ecc8a19903b2b3e39e"
		ALPINE_KEYS='
alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub:MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA1yHJxQgsHQREclQu4Ohe\nqxTxd1tHcNnvnQTu/UrTky8wWvgXT+jpveroeWWnzmsYlDI93eLI2ORakxb3gA2O\nQ0Ry4ws8vhaxLQGC74uQR5+/yYrLuTKydFzuPaS1dK19qJPXB8GMdmFOijnXX4SA\njixuHLe1WW7kZVtjL7nufvpXkWBGjsfrvskdNA/5MfxAeBbqPgaq0QMEfxMAn6/R\nL5kNepi/Vr4S39Xvf2DzWkTLEK8pcnjNkt9/aafhWqFVW7m3HCAII6h/qlQNQKSo\nGuH34Q8GsFG30izUENV9avY7hSLq7nggsvknlNBZtFUcmGoQrtx3FmyYsIC8/R+B\nywIDAQAB
alpine-devel@lists.alpinelinux.org-5261cecb.rsa.pub:MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwlzMkl7b5PBdfMzGdCT0\ncGloRr5xGgVmsdq5EtJvFkFAiN8Ac9MCFy/vAFmS8/7ZaGOXoCDWbYVLTLOO2qtX\nyHRl+7fJVh2N6qrDDFPmdgCi8NaE+3rITWXGrrQ1spJ0B6HIzTDNEjRKnD4xyg4j\ng01FMcJTU6E+V2JBY45CKN9dWr1JDM/nei/Pf0byBJlMp/mSSfjodykmz4Oe13xB\nCa1WTwgFykKYthoLGYrmo+LKIGpMoeEbY1kuUe04UiDe47l6Oggwnl+8XD1MeRWY\nsWgj8sF4dTcSfCMavK4zHRFFQbGp/YFJ/Ww6U9lA3Vq0wyEI6MCMQnoSMFwrbgZw\nwwIDAQAB
alpine-devel@lists.alpinelinux.org-6165ee59.rsa.pub:MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAutQkua2CAig4VFSJ7v54\nALyu/J1WB3oni7qwCZD3veURw7HxpNAj9hR+S5N/pNeZgubQvJWyaPuQDm7PTs1+\ntFGiYNfAsiibX6Rv0wci3M+z2XEVAeR9Vzg6v4qoofDyoTbovn2LztaNEjTkB+oK\ntlvpNhg1zhou0jDVYFniEXvzjckxswHVb8cT0OMTKHALyLPrPOJzVtM9C1ew2Nnc\n3848xLiApMu3NBk0JqfcS3Bo5Y2b1FRVBvdt+2gFoKZix1MnZdAEZ8xQzL/a0YS5\nHd0wj5+EEKHfOd3A75uPa/WQmA+o0cBFfrzm69QDcSJSwGpzWrD1ScH3AK8nWvoj\nv7e9gukK/9yl1b4fQQ00vttwJPSgm9EnfPHLAtgXkRloI27H6/PuLoNvSAMQwuCD\nhQRlyGLPBETKkHeodfLoULjhDi1K2gKJTMhtbnUcAA7nEphkMhPWkBpgFdrH+5z4\nLxy+3ek0cqcI7K68EtrffU8jtUj9LFTUC8dERaIBs7NgQ/LfDbDfGh9g6qVj1hZl\nk9aaIPTm/xsi8v3u+0qaq7KzIBc9s59JOoA8TlpOaYdVgSQhHHLBaahOuAigH+VI\nisbC9vmqsThF2QdDtQt37keuqoda2E6sL7PUvIyVXDRfwX7uMDjlzTxHTymvq2Ck\nhtBqojBnThmjJQFgZXocHG8CAwEAAQ==
-'
		;;
	riscv64)
		APK_TOOLS_URI="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.4/riscv64/apk.static"
		APK_TOOLS_SHA256="312fc603c41d371f1808236574d48f3ef64f8ff0ddde40cc90f21c5f0326135d"
		ALPINE_KEYS='
alpine-devel@lists.alpinelinux.org-60ac2099.rsa.pub:MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwR4uJVtJOnOFGchnMW5Y\nj5/waBdG1u5BTMlH+iQMcV5+VgWhmpZHJCBz3ocD+0IGk2I68S5TDOHec/GSC0lv\n6R9o6F7h429GmgPgVKQsc8mPTPtbjJMuLLs4xKc+viCplXc0Nc0ZoHmCH4da6fCV\ntdpHQjVe6F9zjdquZ4RjV6R6JTiN9v924dGMAkbW/xXmamtz51FzondKC52Gh8Mo\n/oA0/T0KsCMCi7tb4QNQUYrf+Xcha9uus4ww1kWNZyfXJB87a2kORLiWMfs2IBBJ\nTmZ2Fnk0JnHDb8Oknxd9PvJPT0mvyT8DA+KIAPqNvOjUXP4bnjEHJcoCP9S5HkGC\nIQIDAQAB
alpine-devel@lists.alpinelinux.org-616db30d.rsa.pub:MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAnpUpyWDWjlUk3smlWeA0\nlIMW+oJ38t92CRLHH3IqRhyECBRW0d0aRGtq7TY8PmxjjvBZrxTNDpJT6KUk4LRm\na6A6IuAI7QnNK8SJqM0DLzlpygd7GJf8ZL9SoHSH+gFsYF67Cpooz/YDqWrlN7Vw\ntO00s0B+eXy+PCXYU7VSfuWFGK8TGEv6HfGMALLjhqMManyvfp8hz3ubN1rK3c8C\nUS/ilRh1qckdbtPvoDPhSbTDmfU1g/EfRSIEXBrIMLg9ka/XB9PvWRrekrppnQzP\nhP9YE3x/wbFc5QqQWiRCYyQl/rgIMOXvIxhkfe8H5n1Et4VAorkpEAXdsfN8KSVv\nLSMazVlLp9GYq5SUpqYX3KnxdWBgN7BJoZ4sltsTpHQ/34SXWfu3UmyUveWj7wp0\nx9hwsPirVI00EEea9AbP7NM2rAyu6ukcm4m6ATd2DZJIViq2es6m60AE6SMCmrQF\nwmk4H/kdQgeAELVfGOm2VyJ3z69fQuywz7xu27S6zTKi05Qlnohxol4wVb6OB7qG\nLPRtK9ObgzRo/OPumyXqlzAi/Yvyd1ZQk8labZps3e16bQp8+pVPiumWioMFJDWV\nGZjCmyMSU8V6MB6njbgLHoyg2LCukCAeSjbPGGGYhnKLm1AKSoJh3IpZuqcKCk5C\n8CM1S15HxV78s9dFntEqIokCAwEAAQ==
-'
		;;
	ppc64le)
		APK_TOOLS_URI="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.4/ppc64le/apk.static"
		APK_TOOLS_SHA256="556f402287a43bd2a3c3b9b97ea76ba97d365794aa5be7ed448de3ba554e44e7"
		ALPINE_KEYS='
alpine-devel@lists.alpinelinux.org-58cbb476.rsa.pub:MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAoSPnuAGKtRIS5fEgYPXD\n8pSGvKAmIv3A08LBViDUe+YwhilSHbYXUEAcSH1KZvOo1WT1x2FNEPBEFEFU1Eyc\n+qGzbA03UFgBNvArurHQ5Z/GngGqE7IarSQFSoqewYRtFSfp+TL9CUNBvM0rT7vz\n2eMu3/wWG+CBmb92lkmyWwC1WSWFKO3x8w+Br2IFWvAZqHRt8oiG5QtYvcZL6jym\nY8T6sgdDlj+Y+wWaLHs9Fc+7vBuyK9C4O1ORdMPW15qVSl4Lc2Wu1QVwRiKnmA+c\nDsH/m7kDNRHM7TjWnuj+nrBOKAHzYquiu5iB3Qmx+0gwnrSVf27Arc3ozUmmJbLj\nzQIDAQAB
alpine-devel@lists.alpinelinux.org-616abc23.rsa.pub:MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA0MfCDrhODRCIxR9Dep1s\neXafh5CE5BrF4WbCgCsevyPIdvTeyIaW4vmO3bbG4VzhogDZju+R3IQYFuhoXP5v\nY+zYJGnwrgz3r5wYAvPnLEs1+dtDKYOgJXQj+wLJBW1mzRDL8FoRXOe5iRmn1EFS\nwZ1DoUvyu7/J5r0itKicZp3QKED6YoilXed+1vnS4Sk0mzN4smuMR9eO1mMCqNp9\n9KTfRDHTbakIHwasECCXCp50uXdoW6ig/xUAFanpm9LtK6jctNDbXDhQmgvAaLXZ\nLvFqoaYJ/CvWkyYCgL6qxvMvVmPoRv7OPcyni4xR/WgWa0MSaEWjgPx3+yj9fiMA\n1S02pFWFDOr5OUF/O4YhFJvUCOtVsUPPfA/Lj6faL0h5QI9mQhy5Zb9TTaS9jB6p\nLw7u0dJlrjFedk8KTJdFCcaGYHP6kNPnOxMylcB/5WcztXZVQD5WpCicGNBxCGMm\nW64SgrV7M07gQfL/32QLsdqPUf0i8hoVD8wfQ3EpbQzv6Fk1Cn90bZqZafg8XWGY\nwddhkXk7egrr23Djv37V2okjzdqoyLBYBxMz63qQzFoAVv5VoY2NDTbXYUYytOvG\nGJ1afYDRVWrExCech1mX5ZVUB1br6WM+psFLJFoBFl6mDmiYt0vMYBddKISsvwLl\nIJQkzDwtXzT2cSjoj3T5QekCAwEAAQ==
-'
		;;
	aarch64)
		APK_TOOLS_URI="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.4/aarch64/apk.static"
		APK_TOOLS_SHA256="0fbf66c343240dacd2ef5a31692542efcf107dbad35896caa4c3179a3bbed1e2"
		ALPINE_KEYS='
alpine-devel@lists.alpinelinux.org-58199dcc.rsa.pub:MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3v8/ye/V/t5xf4JiXLXa\nhWFRozsnmn3hobON20GdmkrzKzO/eUqPOKTpg2GtvBhK30fu5oY5uN2ORiv2Y2ht\neLiZ9HVz3XP8Fm9frha60B7KNu66FO5P2o3i+E+DWTPqqPcCG6t4Znk2BypILcit\nwiPKTsgbBQR2qo/cO01eLLdt6oOzAaF94NH0656kvRewdo6HG4urbO46tCAizvCR\nCA7KGFMyad8WdKkTjxh8YLDLoOCtoZmXmQAiwfRe9pKXRH/XXGop8SYptLqyVVQ+\ntegOD9wRs2tOlgcLx4F/uMzHN7uoho6okBPiifRX+Pf38Vx+ozXh056tjmdZkCaV\naQIDAQAB
alpine-devel@lists.alpinelinux.org-616ae350.rsa.pub:MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAyduVzi1mWm+lYo2Tqt/0\nXkCIWrDNP1QBMVPrE0/ZlU2bCGSoo2Z9FHQKz/mTyMRlhNqTfhJ5qU3U9XlyGOPJ\npiM+b91g26pnpXJ2Q2kOypSgOMOPA4cQ42PkHBEqhuzssfj9t7x47ppS94bboh46\nxLSDRff/NAbtwTpvhStV3URYkxFG++cKGGa5MPXBrxIp+iZf9GnuxVdST5PGiVGP\nODL/b69sPJQNbJHVquqUTOh5Ry8uuD2WZuXfKf7/C0jC/ie9m2+0CttNu9tMciGM\nEyKG1/Xhk5iIWO43m4SrrT2WkFlcZ1z2JSf9Pjm4C2+HovYpihwwdM/OdP8Xmsnr\nDzVB4YvQiW+IHBjStHVuyiZWc+JsgEPJzisNY0Wyc/kNyNtqVKpX6dRhMLanLmy+\nf53cCSI05KPQAcGj6tdL+D60uKDkt+FsDa0BTAobZ31OsFVid0vCXtsbplNhW1IF\nHwsGXBTVcfXg44RLyL8Lk/2dQxDHNHzAUslJXzPxaHBLmt++2COa2EI1iWlvtznk\nOk9WP8SOAIj+xdqoiHcC4j72BOVVgiITIJNHrbppZCq6qPR+fgXmXa+sDcGh30m6\n9Wpbr28kLMSHiENCWTdsFij+NQTd5S47H7XTROHnalYDuF1RpS+DpQidT5tUimaT\nJZDr++FjKrnnijbyNF8b98UCAwEAAQ==
-'
		;;
	*)
		die "Unsupported architecture: ${ARCH}"
		;;
esac

# Mount a tmpfs to use as the rootfs.
mount -t tmpfs -o "${TMPFS_OPTIONS}" none "${TO}" || die "Failed to mount tmpfs!"

# Add an environment variable to indicate that the script is being run from takeover.sh.
export __RUN_FROM_TAKEOVER_SH=1

# Export the variables for the stage scripts.
export ALPINE_BRANCH ALPINE_KEYS APK_TOOLS_SHA256 APK_TOOLS_URI PACKAGES # stage1.sh
export SSH_PASSWORD SSH_PORT TO # stage2.sh

# Execute the first stage script to create the Alpine Linux rootfs.
/bin/sh ./stage1.sh "${TO}" || die "Failed to create Alpine Linux rootfs!"

# Execute the second stage script to pivot into the new rootfs.
exec /bin/sh ./stage2.sh
