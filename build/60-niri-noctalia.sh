#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Niri + Noctalia desktop
###############################################################################
# Replaces the GNOME desktop inherited from Bluefin with the niri compositor and
# the Noctalia shell. Destructive on purpose: GNOME is removed, not added beside.
#
# niri and noctalia are in Fedora's repositories. Ghostty comes from a COPR and
# the greeter from Terra, each isolated to the one package it provides.
#
# The Containerfile sets install_weak_deps=0, so every package is named here.
###############################################################################

# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

shopt -s nullglob

echo "::group:: Install niri and Noctalia"

# xwayland-satellite is niri's hard requirement today; named anyway, because a
# demotion to Recommends would silently drop X11 support.
dnf5 install -y \
	niri \
	xwayland-satellite \
	noctalia \
	sound-theme-freedesktop

echo "::endgroup::"

echo "::group:: Install session support packages"

# Weak dependencies of niri and noctalia, plus the utilities niri's defaults and
# Noctalia's screenshot panel shell out to. ddcutil drives brightness on
# external monitors; gnome-keyring-pam unlocks the keyring at login.
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

# Ghostty is not in Fedora's repositories.
copr_install_isolated "scottames/ghostty" ghostty

# From the base image, and outside the GNOME removal's closure below. Named
# because /etc/niri/config.kdl binds Mod+E to it.
dnf5 install -y nautilus

echo "::endgroup::"

echo "::group:: Install the greeter"

###############################################################################
# Switching the greeter
###############################################################################
# gdm hard-requires gnome-shell and gnome-session (`rpm -q --requires gdm`), so
# removing GNOME takes the greeter with it and one has to be chosen.
#
# Noctalia Greeter is the login screen from the same project as the shell, so
# the two share a visual language and `noctalia msg greeter-sync` pushes the
# session's wallpaper and palette to it. It is a greetd greeter and brings its
# own wlroots compositor, so nothing here needs an X server or a kiosk
# compositor, and it reads /usr/share/wayland-sessions unaided.
###############################################################################

# Fedora does not package it; Terra, which upstream's install guide points
# Fedora users at, does. Restricted two ways:
#
#   includepkgs  Terra's own noctalia is older than Fedora's and would be free
#                to downgrade the shell. Only the greeter may come from here.
#   gpgkey       Terra publishes no .repo file to inherit, and signs each
#                Fedora release with a different key. Pinning per major makes a
#                rebase fail here until someone verifies the new key, which is
#                the point: a rotated trust root should be a decision.
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

# greetd is a hard requirement of the greeter; named to keep the display
# manager visible here rather than arriving as somebody else's dependency.
dnf5 install -y greetd noctalia-greeter

# A third-party repository is a build-time source only.
rm -f /etc/yum.repos.d/terra.repo

echo "::endgroup::"

echo "::group:: Remove GNOME"

# The -session packages own /usr/share/wayland-sessions, so leaving them would
# keep offering a session that can no longer start. dnf5 takes the dependents
# along; nautilus, ptyxis, gnome-keyring and both portal backends are outside
# that closure and stay.
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

# Every check below is a way the image boots to a black screen, which a
# container build cannot otherwise catch. Fail here instead.

test -f /usr/share/wayland-sessions/niri.desktop
if compgen -G "/usr/share/wayland-sessions/gnome*.desktop" >/dev/null; then
	echo "ERROR: a GNOME session entry survived the removal" >&2
	exit 1
fi

# niri speaks Mutter's ScreenCast D-Bus API, so the GNOME portal backend stays
# correct with mutter gone. niri's own niri-portals.conf names these three
# backends, which is why this image ships no portal config of its own.
rpm -q xdg-desktop-portal-gnome xdg-desktop-portal-gtk gnome-keyring
test -f /usr/share/xdg-desktop-portal/niri-portals.conf

# custom/files placed the config during the overlay phase; this is the first
# point in the build where a compositor exists to check it.
niri validate --config /etc/niri/config.kdl

# Every bind in that config is an IPC call into a running Noctalia.
noctalia --version

# greetd must run the wrapper, not the greeter binary: the wrapper starts the
# bundled compositor. The assets tree carries the fonts, icons and UI; the
# Polkit action is what lets `greeter-sync` apply the session's theme.
test -x /usr/bin/noctalia-greeter-session
test -x /usr/bin/noctalia-greeter
test -x /usr/bin/noctalia-greeter-compositor
test -d /usr/share/noctalia-greeter/assets
test -x /usr/bin/noctalia-greeter-apply-appearance
test -f /usr/share/polkit-1/actions/org.noctalia.greeter.apply-appearance.policy

echo "::endgroup::"

echo "::group:: Configure and enable the greeter"

# Written here rather than through custom/files: greetd owns this path, so an
# overlaid copy would have been moved aside as .rpmsave when greetd installed.
#
# greetd's own service account stands in for upstream's `greeter`, which on
# Fedora would duplicate it. The session is left unpinned so the picker stays
# meaningful if a second one is ever added.
mkdir -p /etc/greetd
cat >/etc/greetd/config.toml <<'EOF'
# Written by build/60-niri-noctalia.sh. Replaced on every image update.
[terminal]
vt = 1

[default_session]
command = "/usr/bin/noctalia-greeter-session"
user = "greetd"
EOF

# The greeter needs a logind session to reach the seat's DRM and input devices;
# Fedora only reaches pam_systemd through system-auth, optionally. Use the
# vendor's helper, then drop the timestamped backup it leaves: every build
# starts from the same base layer, so it has nothing to restore.
/usr/share/noctalia-greeter/setup_greetd_pam.sh
rm -f /etc/pam.d/greetd.bak.noctalia.*
grep -q 'pam_systemd.so' /etc/pam.d/greetd

# /var/lib/noctalia-greeter cannot ship in the image -- 90-cleanup.sh prunes
# /var -- so a unit from custom/files creates it on first boot, before greetd.
systemctl enable noctalia-greeter-setup.service

# gdm's removal leaves the display-manager alias dangling, and systemctl will
# not replace an existing symlink: skipping this boots to no greeter at all.
rm -f /etc/systemd/system/display-manager.service
systemctl enable greetd.service

systemctl set-default graphical.target

echo "::endgroup::"

echo "::group:: Record the desktop in the image identity"

# fastfetch and `bootc status` read os-release; VARIANT is how an installed
# system says which desktop it carries. 00-image-info.sh owns the rest.
sed -i '/^VARIANT=/d; /^VARIANT_ID=/d' /usr/lib/os-release
cat >>/usr/lib/os-release <<'EOF'
VARIANT="Niri"
VARIANT_ID=niri
EOF

echo "::endgroup::"

shopt -u nullglob

echo "Niri + Noctalia phase complete!"
