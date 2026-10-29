#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Prepare Noctalia Greeter for this machine
###############################################################################
# Two things the image cannot carry, both done before greetd starts:
#
#   the state directory  /var/lib/noctalia-greeter holds greeter.toml and
#                        sync.toml, and build/90-cleanup.sh prunes /var.
#   the keyboard layout  a per-machine setting, and the one thing standing
#                        between a correct password and a PAM AUTH_ERR.
#
# The greeter's bundled wlroots compositor builds its keymap with
# xkb_keymap_new_from_names and reads no locale1 state of its own, so a
# greeter.toml with no [keyboard] section -- which is exactly what
# `noctalia-greeter-apply-appearance --setup-system` writes -- leaves
# libxkbcommon to fall back to its built-in default of "us". Every keystroke of
# a password then maps through QWERTY and pam_unix rejects it. niri has the
# opposite behaviour, which is why /etc/niri/config.kdl leaves its xkb block
# empty: the session followed the machine while the login screen did not.
#
# systemd-localed is the source of truth. It writes the X11 keymap to
# /etc/vconsole.conf on current systemd and to Xorg's snippet on every version,
# so both are read and the first answer wins.
#
# Every path is overridable so the test suite can run this against a sandbox.
###############################################################################

GREETER_USER="${GREETER_USER:-greetd}"
STATE_DIR="${NOCTALIA_GREETER_STATE_DIR:-/var/lib/noctalia-greeter}"
GREETER_TOML="${STATE_DIR}/greeter.toml"
VCONSOLE_CONF="${VCONSOLE_CONF:-/etc/vconsole.conf}"
XORG_KEYBOARD_CONF="${XORG_KEYBOARD_CONF:-/etc/X11/xorg.conf.d/00-keyboard.conf}"
APPLY_APPEARANCE="${APPLY_APPEARANCE:-/usr/bin/noctalia-greeter-apply-appearance}"

# KEY=value from an environment file, unquoted. Returns empty for an unset or
# empty assignment, so a caller can treat both the same way.
read_env_value() {
	local file="$1" key="$2" value
	[[ -f "${file}" ]] || return 0
	value="$(sed -nE "s/^[[:space:]]*${key}=(.*)\$/\1/p" "${file}" | tail -n 1)"
	value="${value%\"}"
	value="${value#\"}"
	value="${value%\'}"
	value="${value#\'}"
	printf '%s' "${value}"
}

# Option "XkbLayout" "ch" from Xorg's InputClass snippet.
read_xorg_value() {
	local file="$1" key="$2"
	[[ -f "${file}" ]] || return 0
	sed -nE "s/^[[:space:]]*Option[[:space:]]+\"${key}\"[[:space:]]+\"(.*)\"[[:space:]]*\$/\1/p" \
		"${file}" | tail -n 1
}

###############################################################################
# Create the state directory
###############################################################################

if [[ ! -f "${GREETER_TOML}" ]]; then
	echo "noctiri: creating ${GREETER_TOML}"
	GREETER_USER="${GREETER_USER}" "${APPLY_APPEARANCE}" --setup-system
fi

# Nothing below can run without it, and a greeter with no state directory is a
# failure worth seeing in `systemctl status` rather than one to paper over.
if [[ ! -f "${GREETER_TOML}" ]]; then
	echo "ERROR: ${APPLY_APPEARANCE} did not create ${GREETER_TOML}" >&2
	exit 1
fi

###############################################################################
# Sync the keyboard layout
###############################################################################

layout="$(read_env_value "${VCONSOLE_CONF}" XKBLAYOUT)"
variant="$(read_env_value "${VCONSOLE_CONF}" XKBVARIANT)"
options="$(read_env_value "${VCONSOLE_CONF}" XKBOPTIONS)"

if [[ -z "${layout}" ]]; then
	layout="$(read_xorg_value "${XORG_KEYBOARD_CONF}" XkbLayout)"
	variant="$(read_xorg_value "${XORG_KEYBOARD_CONF}" XkbVariant)"
	options="$(read_xorg_value "${XORG_KEYBOARD_CONF}" XkbOptions)"
fi

# No configured layout means the machine is on the default already. Writing
# layout = "" would pin the greeter to it rather than leave it free, so stop.
if [[ -z "${layout}" ]]; then
	echo "noctiri: no X11 keymap configured; leaving the greeter's layout alone"
	exit 0
fi

echo "noctiri: greeter keyboard layout=${layout} variant=${variant:-none} options=${options:-none}"

# greeter.toml is documented as declarative and hand-editable, so rewrite only
# the three keys this owns and carry every other line of [keyboard] -- numlock,
# most likely -- across untouched. Doing it as a rewrite rather than an append
# is what makes a second boot, or a later `localectl set-x11-keymap`, land on
# the same file instead of stacking sections.
tmp="$(mktemp "${GREETER_TOML}.noctiri.XXXXXXXXXX")"
trap 'rm -f -- "${tmp}"' EXIT

{
	awk '
		# A table header both closes the previous table and opens the next one.
		/^[[:space:]]*\[/ { in_keyboard = ($0 ~ /^[[:space:]]*\[keyboard\][[:space:]]*$/) }
		!in_keyboard { print }
	' "${GREETER_TOML}"

	printf '\n[keyboard]\n'
	printf '# Written by /usr/libexec/noctiri-greeter-setup.sh from systemd-localed.\n'
	printf '# Change it with: localectl set-x11-keymap\n'
	printf 'layout = "%s"\n' "${layout}"
	if [[ -n "${variant}" ]]; then
		printf 'variant = "%s"\n' "${variant}"
	fi
	if [[ -n "${options}" ]]; then
		printf 'options = "%s"\n' "${options}"
	fi

	# Keys of [keyboard] this script does not own.
	awk '
		/^[[:space:]]*\[/ { in_keyboard = ($0 ~ /^[[:space:]]*\[keyboard\][[:space:]]*$/); next }
		!in_keyboard { next }
		/^[[:space:]]*(layout|variant|options)[[:space:]]*=/ { next }
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*$/ { next }
		{ print }
	' "${GREETER_TOML}"
} >"${tmp}"

install -m 0640 "${tmp}" "${GREETER_TOML}"
chown "${GREETER_USER}:${GREETER_USER}" "${GREETER_TOML}" 2>/dev/null ||
	echo "warn: could not chown ${GREETER_TOML} to ${GREETER_USER}" >&2
