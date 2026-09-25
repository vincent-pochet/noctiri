#!/usr/bin/env bats
# Unit tests for build/70-remove-virtualization.sh.
#
# A removal phase fails in two directions: it can match nothing and ship the
# stack anyway, or it can reach past its target and take the desktop or the
# container tools with it. Both are what these tests are about; the exact
# package list is not.
#
# Each test rewrites a throwaway copy so /etc and /usr point into a sandbox,
# then stubs what the script shells out to. The rpm stub answers from
# MOCK_INSTALLED, so a test can put a package back and watch the verification
# block fail.
#
# Run with: bats tests/template/70-remove-virtualization_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_SRC="${REPO_ROOT}/build/70-remove-virtualization.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/70-virt.${BATS_TEST_NUMBER:-0}.$$"
	ROOT="${TEST_ROOT}/root"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	SCRIPT="${TEST_ROOT}/70-remove-virtualization.sh"

	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"
	RPM_LOG="${TEST_ROOT}/logs/rpm.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" \
		"${ROOT}/usr/bin" \
		"${ROOT}/usr/lib/systemd/system" \
		"${ROOT}/usr/lib/tmpfiles.d"

	# The helper the base image writes itself, and its enablement.
	printf '[Unit]\nDescription=Workaround\n' \
		>"${ROOT}/usr/lib/systemd/system/libvirt-workaround.service"
	printf 'd /var/log/libvirt 0750 - - - -\n' \
		>"${ROOT}/usr/lib/tmpfiles.d/libvirt-workaround.conf"

	# Line 1 is excluded so the shebang keeps pointing at the real /usr/bin/env.
	# Both forms matter: mid-line, and a bare command at column 0.
	sed -e "1!s#^\\(/etc/\\|/usr/\\)#${ROOT}\\1#" \
		-e "1!s#\\([^[:alnum:]_.-]\\)/etc/#\\1${ROOT}/etc/#g" \
		-e "1!s#\\([^[:alnum:]_.-]\\)/usr/#\\1${ROOT}/usr/#g" \
		"${BUILD_SRC}" >"${SCRIPT}"

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SYSTEMCTL_LOG RPM_LOG

	# What the image is expected to still carry once the phase has run: the
	# guest side, the libraries the desktop links, and the container stack.
	: "${MOCK_INSTALLED:=qemu-guest-agent spice-vdagent virt-what libosinfo localsearch nautilus podman docker-ce incus}"
	export MOCK_INSTALLED

	for tool in dnf5 systemctl; do
		local log_var
		log_var="$(printf '%s' "${tool}" | tr '[:lower:]' '[:upper:]')_LOG"
		cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "\${${log_var}}"
exit 0
EOF
		chmod +x "${STUB_BIN}/${tool}"
	done

	# rpm -q answers from MOCK_INSTALLED, so both halves of the verification
	# block can be driven: a survivor put back, or a keeper taken away.
	cat >"${STUB_BIN}/rpm" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${RPM_LOG}"
[[ "$1" == "-q" ]] || exit 0
shift
for package in "$@"; do
    case " ${MOCK_INSTALLED} " in
        *" ${package} "*) ;;
        *) printf 'package %s is not installed\n' "${package}"; exit 1 ;;
    esac
done
exit 0
EOF
	chmod +x "${STUB_BIN}/rpm"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

# The removal arguments, as one line, for the membership assertions below.
_removal() {
	grep -E '^remove -y ' "${DNF5_LOG}"
}

@test "70-remove-virtualization: sandbox rewrite left no writes to the real filesystem" {
	# Guards the rewrite: an unmatched path would edit the host for real.
	run grep -nE '(^|[^[:alnum:]_.-])(/etc|/usr)/' <(tail -n +2 "${SCRIPT}")
	[ "$status" -ne 0 ]
}

@test "70-remove-virtualization: completes successfully" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "70-remove-virtualization: emits GitHub Actions group markers" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"::group:: Remove the virtualization stack"* ]]
	[[ "$output" == *"::group:: Drop the base image's libvirt helper"* ]]
	[[ "$output" == *"::group:: Verify the virtualization stack is gone"* ]]
	[[ "$output" == *"::endgroup::"* ]]
}

@test "70-remove-virtualization: removes the host stack in one transaction" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# One transaction, so dnf5 resolves dependents and orphans against the
	# whole set rather than against each group in turn.
	[ "$(grep -cE '^remove -y ' "${DNF5_LOG}")" -eq 1 ]

	local removal
	removal="$(_removal)"
	for package in 'libvirt*' virt-manager virt-install virt-v2v virtiofsd \
		'libguestfs*' qemu qemu-common qemu-img qemu-kvm 'qemu-system-*' \
		'qemu-user*' 'edk2-*' 'swtpm*' spice-server; do
		[[ "${removal}" == *" ${package} "* || "${removal}" == *" ${package}" ]] || {
			echo "not removed: ${package}" >&2
			return 1
		}
	done
}

@test "70-remove-virtualization: keeps the guest side and what the desktop links" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# qemu-guest-agent and spice-vdagent are what makes this image behave when
	# it is the guest; tuned requires virt-what; nautilus requires localsearch,
	# which links libosinfo. A wider removal list must not quietly take them.
	local removal
	removal="$(_removal)"
	for package in qemu-guest-agent spice-vdagent spice-webdavd virt-what \
		libosinfo osinfo-db passt slirp4netns; do
		[[ "${removal}" != *"${package}"* ]] || {
			echo "removed a package the image still needs: ${package}" >&2
			return 1
		}
	done
}

@test "70-remove-virtualization: never passes a bare qemu glob to dnf5" {
	# `qemu*` would match qemu-guest-agent, and nothing downstream would notice
	# the guest integration going missing.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local removal
	removal="$(_removal)"
	[[ "${removal}" != *" qemu* "* && "${removal}" != *" qemu*" ]]
}

@test "70-remove-virtualization: disables and deletes the base image's libvirt helper" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# Not owned by any package, so the removal above leaves it behind.
	grep -qx 'disable libvirt-workaround.service' "${SYSTEMCTL_LOG}"
	[ ! -e "${ROOT}/usr/lib/systemd/system/libvirt-workaround.service" ]
	[ ! -e "${ROOT}/usr/lib/tmpfiles.d/libvirt-workaround.conf" ]
}

@test "70-remove-virtualization: tolerates a base image that ships no libvirt helper" {
	rm -f "${ROOT}/usr/lib/systemd/system/libvirt-workaround.service" \
		"${ROOT}/usr/lib/tmpfiles.d/libvirt-workaround.conf"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# Disabling a unit that does not exist is an error, so it must not be tried.
	[ ! -s "${SYSTEMCTL_LOG}" ]
}

@test "70-remove-virtualization: fails when a virtualization package survives" {
	MOCK_INSTALLED="${MOCK_INSTALLED} libvirt-daemon"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"libvirt-daemon survived the removal"* ]]
}

@test "70-remove-virtualization: fails when a QEMU binary survives" {
	# A package set can look right while the binaries are still on disk.
	: >"${ROOT}/usr/bin/qemu-system-x86_64"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"survived the removal"* ]]
}

@test "70-remove-virtualization: fails when the removal takes the file manager with it" {
	# nautilus requires localsearch, which links libosinfo: removing libosinfo
	# takes both. The verification block is what catches that.
	MOCK_INSTALLED="qemu-guest-agent spice-vdagent virt-what podman docker-ce incus"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "70-remove-virtualization: fails when the removal takes the container stack with it" {
	MOCK_INSTALLED="qemu-guest-agent spice-vdagent virt-what libosinfo localsearch nautilus"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}
