#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Niri + Noctalia desktop
###############################################################################
# Replaces the GNOME desktop this image inherits from Bluefin with the niri
# scrolling compositor and the Noctalia shell.
#
# Both come from Fedora's own repositories -- niri and noctalia are packaged
# there, so neither needs a COPR. Ghostty is the one exception and is installed
# from a COPR, isolated the way copr-helpers.sh does it.
#
# The phase is destructive on purpose: it removes GNOME rather than adding niri
# beside it. Read "Switching the greeter" below before changing the removal
# list, because gdm cannot survive it.
#
# The Containerfile sets install_weak_deps=0 for the whole build, so nothing
# here arrives by Recommends. Every package a working session needs is named.
###############################################################################

# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

shopt -s nullglob

echo "::group:: Install niri and Noctalia"

# niri hard-requires xwayland-satellite and starts it on demand, so X11 clients
# work without a session-wide Xwayland. It is named anyway: it is load-bearing
# for this desktop, and a silent upstream demotion to Recommends would drop it.
#
# noctalia is the shell itself: bar, dock, launcher, notifications, control
# centre, wallpaper, clipboard history, lock screen and settings UI in one
# binary. sound-theme-freedesktop is its runtime dependency for event sounds.
dnf5 install -y \
	niri \
	xwayland-satellite \
	noctalia \
	sound-theme-freedesktop

echo "::endgroup::"

echo "::group:: Install session support packages"

# Weak dependencies of niri and noctalia that this image genuinely wants, plus
# the Wayland utilities niri's defaults and Noctalia's screenshot panel call:
#
#   gnome-keyring{,-pam}  Secret Service provider; the PAM module unlocks the
#                         keyring at login, which Fedora's /etc/pam.d/greetd
#                         already calls when it is present
#   upower                battery and power-profile readings for the bar
#   ddcutil               brightness on external monitors over DDC/CI
#   grim, slurp           capture and region selection
#   wl-clipboard          clipboard access for scripts and for wl-copy/wl-paste
#   brightnessctl         sysfs backlight fallback
#   playerctl             MPRIS media control
dnf5 install -y \
	gnome-keyring \
	gnome-keyring-pam \
	upower \
	ddcutil \
	grim \
	slurp \
	wl-clipboard \
	brightnessctl \
	playerctl

echo "::endgroup::"

echo "::group:: Install the terminal and file manager"

# Ghostty is not in Fedora's repositories. scottames/ghostty is the COPR that
# tracks upstream's tagged releases; copr_install_isolated enables it only for
# this transaction and leaves it disabled in the image.
copr_install_isolated "scottames/ghostty" ghostty

# nautilus comes from the base image and survives the GNOME removal below --
# only its gsconnect and python extensions go with gnome-shell. Naming it here
# makes the dependency explicit: /etc/niri/config.kdl binds Mod+E to it.
dnf5 install -y nautilus

echo "::endgroup::"

echo "::group:: Install the greeter"

###############################################################################
# Switching the greeter
###############################################################################
# gdm hard-requires gnome-shell, gnome-session and gnome-session-wayland-session
# (`rpm -q --requires gdm`), so removing GNOME removes the greeter with it, and
# niri has no equivalent of COSMIC's bundled cosmic-greeter. One has to be
# chosen.
#
# Noctalia Greeter is the one this image wants: it is the login screen the same
# project builds for its shell, so the greeter and the session share a visual
# language instead of merely coexisting, and `noctalia msg greeter-sync` pushes
# the shell's wallpaper and colour palette to it. It is graphical and themable
# -- see "Theming" in README.md and greeter.toml's own header, which documents
# every key it takes.
#
# It is a greetd greeter, so greetd is the display manager: greetd runs
# noctalia-greeter-session, which starts the greeter's own bundled wlroots
# compositor and runs the greeter inside it. That is why nothing here needs an
# X server -- the base image ships Xwayland but no xorg-x11-server-Xorg -- and
# why no separate kiosk compositor is installed either.
#
# It reads /usr/share/wayland-sessions, so niri.desktop appears in its session
# picker with no extra wiring.
###############################################################################

# Fedora does not package it; Terra, the community repository upstream's own
# installation guide points Fedora users at, does. The repository is added for
# this transaction and taken back out below, the way
# 30-tailscale.sh.example does it, with two extra restrictions:
#
#   includepkgs   Terra also carries noctalia, noctalia-nightly, noctalia-qs
#                 and noctalia-legacy. Its noctalia is 5.0.0~beta.9 -- older
#                 than the 5.1.0 this image installs from Fedora -- so an
#                 unrestricted Terra would be free to downgrade the shell.
#                 Only the greeter may come from here.
#   gpgkey        Terra publishes no .repo file to inherit, so this one is
#                 hand-written and the key is pinned by fingerprint.
#
# Terra signs each Fedora release with a different key, so the pin is per
# major. A Fedora rebase therefore fails here, loudly, until someone verifies
# the new key and adds it -- which is the point: a rotated trust root should be
# a decision, not a silent fetch.
declare -A TERRA_KEY_FINGERPRINTS=(
	[43]="47F7A5060E38FC07F674D11BE43DBFE05C4F92A3"
	[44]="AE09157A4DE88B497EA1D5D300CDAB43DE226D6F"
	[45]="C2AC02124AF114F086592E3C8DDE7D14C1C23D8C"
)

FEDORA_MAJOR="$(sed -nE 's/^VERSION_ID=([0-9]+)$/\1/p' /usr/lib/os-release)"
if [[ -z "${FEDORA_MAJOR}" ]]; then
	echo "ERROR: could not read VERSION_ID from /usr/lib/os-release" >&2
	exit 1
fi

EXPECTED_FINGERPRINT="${TERRA_KEY_FINGERPRINTS[${FEDORA_MAJOR}]:-}"
if [[ -z "${EXPECTED_FINGERPRINT}" ]]; then
	echo "ERROR: no pinned Terra signing key for Fedora ${FEDORA_MAJOR}." >&2
	echo "       Verify https://repos.fyralabs.com/terra${FEDORA_MAJOR}/key.asc and add" >&2
	echo "       its fingerprint to TERRA_KEY_FINGERPRINTS in this script." >&2
	exit 1
fi

TERRA_KEY_FILE="/etc/pki/rpm-gpg/RPM-GPG-KEY-terra"
TERRA_GPG_HOME="$(mktemp -d)"
trap 'rm -rf -- "${TERRA_GPG_HOME}"' EXIT

curl --fail --retry 3 --silent --show-error --location \
	--proto '=https' --proto-redir '=https' \
	--output "${TERRA_KEY_FILE}" \
	"https://repos.fyralabs.com/terra${FEDORA_MAJOR}/key.asc"

ACTUAL_FINGERPRINT="$(gpg --batch --homedir "${TERRA_GPG_HOME}" \
	--show-keys --with-colons "${TERRA_KEY_FILE}" |
	awk -F: '$1 == "fpr" { print $10; exit }')"

if [[ "${ACTUAL_FINGERPRINT}" != "${EXPECTED_FINGERPRINT}" ]]; then
	echo "ERROR: Terra signing key fingerprint mismatch for Fedora ${FEDORA_MAJOR}" >&2
	echo "       expected ${EXPECTED_FINGERPRINT}" >&2
	echo "       got      ${ACTUAL_FINGERPRINT:-<none>}" >&2
	exit 1
fi

cat >/etc/yum.repos.d/terra.repo <<EOF
[terra]
name=Terra \$releasever
baseurl=https://repos.fyralabs.com/terra\$releasever
enabled=1
includepkgs=noctalia-greeter
gpgcheck=1
repo_gpgcheck=0
gpgkey=file://${TERRA_KEY_FILE}
EOF

# greetd and wlroots are noctalia-greeter's hard requirements and come from
# Fedora; naming greetd keeps the display manager visible in this list rather
# than arriving as somebody else's dependency.
dnf5 install -y greetd noctalia-greeter

# A third-party repository is a build-time source only. 90-cleanup.sh disables
# leftover repository files as a backstop; this removes it outright.
rm -f /etc/yum.repos.d/terra.repo

echo "::endgroup::"

echo "::group:: Remove GNOME"

# gnome-shell, mutter and gnome-session are what a GNOME session is; the
# -session packages own the files in /usr/share/wayland-sessions, so leaving
# them would keep offering sessions at the greeter that can no longer start.
# gdm goes because it cannot be kept (see above).
#
# dnf5 takes the dependent packages with them: gnome-browser-connector,
# gnome-rounded-blur, the bundled shell extensions, and nautilus-gsconnect and
# nautilus-python, which are gsconnect's. nautilus, ptyxis, gnome-keyring and
# both xdg-desktop-portal backends are not in that closure and stay.
dnf5 remove -y \
	gnome-shell \
	"gnome-shell-extension*" \
	mutter \
	gnome-session \
	gnome-session-wayland-session \
	gnome-classic-session \
	gnome-control-center \
	gnome-initial-setup \
	gdm

echo "::endgroup::"

echo "::group:: Verify the desktop is coherent"

# Each of these is a way the image can boot to a black screen, which is exactly
# what a container build cannot otherwise catch. Fail here instead.

# The session entry the greeter offers. niri ships it; the removal above must
# not have taken it, and nothing else may be left advertising a dead session.
test -f /usr/share/wayland-sessions/niri.desktop
if compgen -G "/usr/share/wayland-sessions/gnome*.desktop" >/dev/null; then
	echo "ERROR: a GNOME session entry survived the removal" >&2
	exit 1
fi

# niri speaks Mutter's ScreenCast D-Bus API, which is why the GNOME portal
# backend is the right one for it even with mutter gone. The GTK backend serves
# file chooser, Access and Notification; gnome-keyring serves Secret. niri's own
# /usr/share/xdg-desktop-portal/niri-portals.conf already names all three, so
# this image ships no portal configuration of its own -- it only has to make
# sure the backends the upstream file names are still installed.
rpm -q xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring
test -f /usr/share/xdg-desktop-portal/niri-portals.conf

# custom/files put the config in place during the overlay phase; niri is only
# here to check it now. A bad bind or an unknown node fails the build.
niri validate --config /etc/niri/config.kdl

# The binds in that config are IPC calls into a running Noctalia. If the binary
# is missing or the package changed name, every one of them is dead.
noctalia --version

# The greeter, checked the same way: each of these is a black screen at boot.
# greetd must run the session wrapper, never the greeter binary directly -- the
# wrapper is what starts the bundled compositor the greeter draws inside.
test -x /usr/bin/noctalia-greeter-session
test -x /usr/bin/noctalia-greeter
test -x /usr/bin/noctalia-greeter-compositor

# The assets tree is required at runtime: without it the greeter starts with no
# fonts, icons or UI resources.
test -d /usr/share/noctalia-greeter/assets

# The helper the first-boot unit calls to lay out the state directory, and the
# Polkit action that lets `noctalia msg greeter-sync` push the session's
# wallpaper and palette to the greeter.
test -x /usr/bin/noctalia-greeter-apply-appearance
test -f /usr/share/polkit-1/actions/org.noctalia.greeter.apply-appearance.policy

echo "::endgroup::"

echo "::group:: Configure and enable the greeter"

# greetd ships /etc/greetd/config.toml as a package config file, so it is
# written here rather than through custom/files: the overlay phase runs before
# this one, and installing greetd afterwards would have moved an overlaid copy
# aside as .rpmsave.
#
# The command is the session wrapper. The user is greetd's own service account,
# created by the greetd package -- upstream's instructions create a second
# account called `greeter`, which on Fedora would be a duplicate of one that
# already exists with the right shell and home. noctalia-greeter resolves the
# greeter account from this file and from the state directory's owner, so
# naming greetd here is all it takes.
#
# The session is deliberately not pinned with `-- --session niri`: leaving it
# unpinned keeps the session picker meaningful if a second session is ever
# added, and niri is the only entry in /usr/share/wayland-sessions today.
mkdir -p /etc/greetd
cat >/etc/greetd/config.toml <<'EOF'
# Written by build/60-niri-noctalia.sh. Replaced on every image update.
[terminal]
vt = 1

[default_session]
command = "/usr/bin/noctalia-greeter-session"
user = "greetd"
EOF

# The greeter needs a logind session to reach the seat's DRM and input devices.
# Fedora's /etc/pam.d/greetd only reaches pam_systemd through system-auth, where
# it is optional; upstream's helper adds it as a required session line. Run the
# vendor's script rather than reimplementing it, then drop the timestamped
# backup it leaves behind -- every build starts from the same base layer, so the
# backup has nothing to restore and would only differ between builds.
/usr/share/noctalia-greeter/setup_greetd_pam.sh
rm -f /etc/pam.d/greetd.bak.noctalia.*
grep -q 'pam_systemd.so' /etc/pam.d/greetd

# The greeter's state lives in /var/lib/noctalia-greeter, and 90-cleanup.sh
# prunes /var: anything written there now is gone from the shipped image. So the
# layout is created on the booted system instead, by a unit shipped through
# custom/files and ordered before greetd.
systemctl enable noctalia-greeter-setup.service

# gdm's removal leaves the display-manager.service alias dangling. Clear it
# before enabling greetd so the alias points at a unit that exists -- systemctl
# will not replace an existing symlink, so skipping this boots to no greeter.
rm -f /etc/systemd/system/display-manager.service
systemctl enable greetd.service

# graphical.target is what boots the greeter. The base image is already there,
# but the default target is cheap to assert and expensive to get wrong.
systemctl set-default graphical.target

echo "::endgroup::"

echo "::group:: Record the desktop in the image identity"

# 00-image-info.sh has already written NAME, VERSION and the ublue fields.
# VARIANT is what is added here: fastfetch and `bootc status` read os-release,
# and "Niri" there is how an installed system says which desktop it carries.
sed -i '/^VARIANT=/d; /^VARIANT_ID=/d' /usr/lib/os-release
cat >>/usr/lib/os-release <<'EOF'
VARIANT="Niri"
VARIANT_ID=niri
EOF

echo "::endgroup::"

shopt -u nullglob

echo "Niri + Noctalia phase complete!"
