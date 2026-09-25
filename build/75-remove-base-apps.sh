#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Remove the base applications this image replaces
###############################################################################
# Four things the `-dx` base ships that this image has its own answer for:
#
#   ptyxis          Bluefin's terminal. 60-niri-noctalia.sh installs Ghostty
#                   and /etc/niri/config.kdl binds Mod+T to it. Nothing
#                   requires or recommends ptyxis, so it leaves on its own.
#   code            Visual Studio Code, from Microsoft's repository and the
#                   single largest package in the image at ~1 GiB. Zed takes
#                   its place, declared as a Flatpak in
#                   custom/flatpaks/default.preinstall. The repository file
#                   goes with it: it ships disabled, and the only thing it can
#                   still do is put the editor back.
#   cockpit-bridge  The web console. Every cockpit-* page requires the bridge,
#                   so they are named alongside it rather than left to the
#                   dependency sweep. No cockpit-ws is installed, so nothing
#                   was serving them here.
#   lxc, incus      The third and fourth container managers, behind Podman and
#                   Docker. incus requires lxcfs and lxc-libs, so the two go
#                   together or not at all; its VM half is gone with QEMU in
#                   any case. incus-agent is named with them: it is the agent
#                   for running *inside* an Incus instance, it depends on
#                   nothing, and it arrived only because incus did.
#
# The dependency sweep that follows takes cockpit-storaged's plumbing with it
# -- the udisks2 btrfs/LVM/iSCSI plugins, setroubleshoot, multipath,
# NetworkManager-team, socat. None of that is in plain `bluefin` either: it
# arrives with Cockpit and leaves with it.
#
# `dnf5 remove` treats a name it cannot match as nothing to do, so a base image
# that stops shipping one of these does not fail the build.
###############################################################################

shopt -s nullglob

echo "::group:: Remove the replaced applications"

dnf5 remove -y \
	ptyxis \
	code \
	cockpit-bridge \
	"cockpit-*" \
	lxc \
	lxc-libs \
	lxc-templates \
	lxcfs \
	incus \
	incus-client \
	incus-agent

echo "::endgroup::"

echo "::group:: Drop the Visual Studio Code repository"

# 90-cleanup.sh disables third-party repositories; this one has nothing left to
# install, so it goes entirely rather than staying behind disabled.
rm -f /etc/yum.repos.d/vscode.repo

echo "::endgroup::"

echo "::group:: Verify the replacements are in place"

for package in ptyxis code cockpit-bridge cockpit-system lxc lxcfs incus \
	incus-agent; do
	if rpm -q "${package}" >/dev/null 2>&1; then
		echo "ERROR: ${package} survived the removal" >&2
		exit 1
	fi
done

if [[ -e /etc/yum.repos.d/vscode.repo ]]; then
	echo "ERROR: the Visual Studio Code repository survived the removal" >&2
	exit 1
fi

# What replaces them: the terminal Mod+T opens, and the container tools that
# outlived the two managers above. Zed is a Flatpak and arrives on first boot,
# so there is nothing to assert for it here.
rpm -q ghostty nautilus
rpm -q podman docker-ce

echo "::endgroup::"

shopt -u nullglob

echo "Base application removal phase complete!"
