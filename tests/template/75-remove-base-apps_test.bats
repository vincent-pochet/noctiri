#!/usr/bin/env bats
# Unit tests for build/75-remove-base-apps.sh.
#
# The phase removes what this image replaces, so the assertions are about the
# replacements surviving as much as about the removals happening.
#
# Each test rewrites a throwaway copy so /etc and /usr point into a sandbox,
# then stubs what the script shells out to. The rpm stub answers from
# MOCK_INSTALLED, so a test can put a package back and watch the verification
# block fail.
#
# Run with: bats tests/template/75-remove-base-apps_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_SRC="${REPO_ROOT}/build/75-remove-base-apps.sh"
PREINSTALL="${REPO_ROOT}/custom/flatpaks/default.preinstall"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/75-apps.${BATS_TEST_NUMBER:-0}.$$"
	ROOT="${TEST_ROOT}/root"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	SCRIPT="${TEST_ROOT}/75-remove-base-apps.sh"

	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	RPM_LOG="${TEST_ROOT}/logs/rpm.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${ROOT}/etc/yum.repos.d"

	# The repository the base image adds for the editor it ships.
	printf '[code]\nname=Visual Studio Code\nenabled=0\n' \
		>"${ROOT}/etc/yum.repos.d/vscode.repo"

	# Line 1 is excluded so the shebang keeps pointing at the real /usr/bin/env.
	# Both forms matter: mid-line, and a bare command at column 0.
	sed -e "1!s#^\\(/etc/\\|/usr/\\)#${ROOT}\\1#" \
		-e "1!s#\\([^[:alnum:]_.-]\\)/etc/#\\1${ROOT}/etc/#g" \
		-e "1!s#\\([^[:alnum:]_.-]\\)/usr/#\\1${ROOT}/usr/#g" \
		"${BUILD_SRC}" >"${SCRIPT}"

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG RPM_LOG

	# What the image is expected to still carry once the phase has run.
	: "${MOCK_INSTALLED:=ghostty nautilus podman docker-ce}"
	export MOCK_INSTALLED

	cat >"${STUB_BIN}/dnf5" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${DNF5_LOG}"
exit 0
EOF
	chmod +x "${STUB_BIN}/dnf5"

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

@test "75-remove-base-apps: sandbox rewrite left no writes to the real filesystem" {
	# Guards the rewrite: an unmatched path would edit the host for real.
	run grep -nE '(^|[^[:alnum:]_.-])(/etc|/usr)/' <(tail -n +2 "${SCRIPT}")
	[ "$status" -ne 0 ]
}

@test "75-remove-base-apps: completes successfully" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "75-remove-base-apps: emits GitHub Actions group markers" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"::group:: Remove the replaced applications"* ]]
	[[ "$output" == *"::group:: Drop the Visual Studio Code repository"* ]]
	[[ "$output" == *"::group:: Verify the replacements are in place"* ]]
	[[ "$output" == *"::endgroup::"* ]]
}

@test "75-remove-base-apps: removes the terminal, the editor, the web console and the container managers" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local removal
	removal="$(grep -E '^remove -y ' "${DNF5_LOG}")"
	for package in ptyxis code cockpit-bridge 'cockpit-*' lxc lxc-libs lxcfs \
		incus incus-client incus-agent; do
		[[ "${removal}" == *" ${package} "* || "${removal}" == *" ${package}" ]] || {
			echo "not removed: ${package}" >&2
			return 1
		}
	done
}

@test "75-remove-base-apps: names incus rather than leaving it to the dependency sweep" {
	# incus requires lxcfs and lxc-libs, so it leaves either way. Naming it is
	# what makes that visible to whoever reads the removal list.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qE '^remove -y .* incus( |$)' "${DNF5_LOG}"
}

@test "75-remove-base-apps: keeps the replacements it verifies" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local removal
	removal="$(grep -E '^remove -y ' "${DNF5_LOG}")"
	for package in ghostty nautilus podman docker-ce; do
		[[ "${removal}" != *"${package}"* ]] || {
			echo "removed a package the image still needs: ${package}" >&2
			return 1
		}
	done
}

@test "75-remove-base-apps: deletes the editor's repository file" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# Disabled by 90-cleanup.sh either way; the only thing it could still do is
	# put the editor back.
	[ ! -e "${ROOT}/etc/yum.repos.d/vscode.repo" ]
}

@test "75-remove-base-apps: tolerates a base image that ships no editor repository" {
	rm -f "${ROOT}/etc/yum.repos.d/vscode.repo"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "75-remove-base-apps: fails when a replaced application survives" {
	MOCK_INSTALLED="${MOCK_INSTALLED} ptyxis"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"ptyxis survived the removal"* ]]
}

@test "75-remove-base-apps: fails when the removal takes the terminal with it" {
	MOCK_INSTALLED="nautilus podman docker-ce"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "75-remove-base-apps: the editor it removes has a declared replacement" {
	# The phase removes Visual Studio Code on the strength of this line; a
	# preinstall file without it would ship an image with no editor at all.
	grep -qx '\[Flatpak Preinstall dev.zed.Zed\]' "${PREINSTALL}"
}
