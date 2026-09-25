#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Remove the host virtualization stack
###############################################################################
# `-dx` ships a full host virtualization stack: libvirt and its daemon drivers,
# QEMU's system and user-mode emulators, virt-manager and virt-install,
# libguestfs, SPICE, swtpm, and the UEFI and BIOS firmware images those boot.
# This image runs containers, not virtual machines, so it all comes out --
# around 260 packages and 2 GiB.
#
# What stays, and why:
#
#   qemu-guest-agent, spice-vdagent, spice-webdavd
#       The guest side, not the host side: they are what makes this image
#       behave when it is itself installed in a VM (`just run-vm-qcow2`, or any
#       hypervisor someone puts it on). None of them link QEMU.
#   virt-what
#       tuned requires it to recognise the hypervisor it is running under.
#   libosinfo, osinfo-db, osinfo-db-tools
#       localsearch links libosinfo and nautilus requires localsearch, so
#       removing it would take the file manager and the indexer with it.
#   passt, slirp4netns
#       Rootless podman networking. Named here because they read as
#       virtualization and are not.
#
# dnf5 takes dependents along, and three of them are worth knowing about:
#
#   podman-machine    requires qemu-system-x86-core and virtiofsd. It exists to
#                     give macOS and Windows a Linux VM to run podman in; this
#                     host runs it natively.
#   cockpit-machines  Cockpit's virtual machines page, with no libvirt left to
#                     talk to.
#   osbuild           requires qemu-img. Disk images are built with
#                     bootc-image-builder instead -- see `just build-qcow2`,
#                     which runs it as a container.
#
# systemtap-{client,devel,runtime} leave too: they are in the base only because
# qemu-tools recommends them, and are not part of what `-dx` declares.
#
# `dnf5 remove` treats a name it cannot match as nothing to do, so a base image
# that stops shipping one of these does not fail the build.
###############################################################################

shopt -s nullglob

echo "::group:: Remove the virtualization stack"

# One transaction, so dnf5 resolves the dependents and the orphaned libraries
# against the whole set rather than against each group in turn.
#
# The qemu-* plugin packages -- audio, block, char, display, UI -- all require
# qemu-common and leave with it. qemu-guest-agent does not require it, which is
# why naming the emulators here does not take the guest agent along.
dnf5 remove -y \
	"libvirt*" \
	python3-libvirt \
	virt-manager \
	virt-manager-common \
	virt-install \
	virt-viewer \
	virt-v2v \
	virtiofsd \
	"libguestfs*" \
	guestfs-tools \
	qemu \
	qemu-common \
	qemu-img \
	qemu-kvm \
	qemu-kvm-core \
	qemu-tools \
	"qemu-system-*" \
	"qemu-user*" \
	"edk2-*" \
	seabios-bin \
	ipxe-roms-qemu \
	"swtpm*" \
	spice-server \
	spice-gtk3 \
	spice-glib

echo "::endgroup::"

echo "::group:: Drop the base image's libvirt helper"

# Not owned by any package -- the base image writes them itself -- so the
# removal above leaves them behind. The unit relabels /var/lib/libvirt, which
# nothing creates any more, and the tmpfiles entry makes /var/log/libvirt.
if [[ -f /usr/lib/systemd/system/libvirt-workaround.service ]]; then
	systemctl disable libvirt-workaround.service
	rm -f /usr/lib/systemd/system/libvirt-workaround.service
fi
rm -f /usr/lib/tmpfiles.d/libvirt-workaround.conf

echo "::endgroup::"

echo "::group:: Verify the virtualization stack is gone"

# A removal that silently matched nothing would ship the stack anyway, and a
# removal that reached too far would take the desktop or the container tools
# with it. Both are cheap to check here and expensive to notice on a booted
# system.
for package in libvirt libvirt-daemon libvirt-client qemu qemu-common qemu-kvm \
	virt-manager virt-install libguestfs swtpm; do
	if rpm -q "${package}" >/dev/null 2>&1; then
		echo "ERROR: ${package} survived the removal" >&2
		exit 1
	fi
done

if [[ -e /usr/bin/qemu-system-x86_64 || -e /usr/bin/virsh ]]; then
	echo "ERROR: a QEMU or libvirt binary survived the removal" >&2
	exit 1
fi

# The guest side, the libraries the desktop links, and the container stack that
# replaces all of the above.
rpm -q qemu-guest-agent spice-vdagent virt-what
rpm -q libosinfo localsearch nautilus
rpm -q podman docker-ce incus

echo "::endgroup::"

shopt -u nullglob

echo "Virtualization removal phase complete!"
