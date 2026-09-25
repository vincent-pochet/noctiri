#!/usr/bin/env bats
# Unit tests for build/60-niri-noctalia.sh.
#
# This phase can leave the image unbootable, and nothing downstream would
# notice a missing session file or portal backend, so most assertions are about
# its guard rails rather than its package list.
#
# Each test rewrites a throwaway copy so /ctx, /etc and /usr point into a
# sandbox, then stubs what the script shells out to. sed, test, mkdir and rm
# stay real.
#
# Run with: bats tests/template/60-niri-noctalia_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_SRC="${REPO_ROOT}/build/60-niri-noctalia.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/60-niri.${BATS_TEST_NUMBER:-0}.$$"
	CTX="${TEST_ROOT}/ctx"
	ROOT="${TEST_ROOT}/root"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	SCRIPT="${TEST_ROOT}/60-niri-noctalia.sh"

	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"
	RPM_LOG="${TEST_ROOT}/logs/rpm.log"
	NIRI_LOG="${TEST_ROOT}/logs/niri.log"
	NOCTALIA_LOG="${TEST_ROOT}/logs/noctalia.log"
	CURL_LOG="${TEST_ROOT}/logs/curl.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${CTX}/build"

	# Sourced verbatim, so a syntax break in the real helper fails here too.
	cp "${REPO_ROOT}/build/copr-helpers.sh" "${CTX}/build/copr-helpers.sh"

	# The tree the script expects, as the base image and overlay phase leave it.
	mkdir -p \
		"${ROOT}/usr/share/wayland-sessions" \
		"${ROOT}/usr/share/xdg-desktop-portal" \
		"${ROOT}/usr/share/noctalia-greeter/assets" \
		"${ROOT}/usr/share/polkit-1/actions" \
		"${ROOT}/usr/bin" \
		"${ROOT}/usr/lib" \
		"${ROOT}/etc/niri" \
		"${ROOT}/etc/pam.d" \
		"${ROOT}/etc/pki/rpm-gpg" \
		"${ROOT}/etc/yum.repos.d" \
		"${ROOT}/etc/systemd/system"
	printf '[Desktop Entry]\nName=Niri\nExec=niri-session\n' \
		>"${ROOT}/usr/share/wayland-sessions/niri.desktop"
	printf '[preferred]\ndefault=gnome;gtk;\n' \
		>"${ROOT}/usr/share/xdg-desktop-portal/niri-portals.conf"
	printf 'NAME="Noctiri"\nID=noctiri\nVERSION_ID=44\nVARIANT="Stale"\nVARIANT_ID=stale\n' \
		>"${ROOT}/usr/lib/os-release"
	cp "${REPO_ROOT}/custom/files/etc/niri/config.kdl" "${ROOT}/etc/niri/config.kdl"
	ln -sf /usr/lib/systemd/system/gdm.service \
		"${ROOT}/etc/systemd/system/display-manager.service"

	# The greeter's side, as the noctalia-greeter package leaves it.
	local binary
	for binary in noctalia-greeter noctalia-greeter-session \
		noctalia-greeter-compositor noctalia-greeter-apply-appearance; do
		printf '#!/usr/bin/bash\nexit 0\n' >"${ROOT}/usr/bin/${binary}"
		chmod +x "${ROOT}/usr/bin/${binary}"
	done
	: >"${ROOT}/usr/share/polkit-1/actions/org.noctalia.greeter.apply-appearance.policy"

	# The vendor's PAM helper: adds the session line, leaves a backup.
	cat >"${ROOT}/usr/share/noctalia-greeter/setup_greetd_pam.sh" <<EOF
#!/usr/bin/bash
printf 'session    required     pam_systemd.so\n' >> "${ROOT}/etc/pam.d/greetd"
cp "${ROOT}/etc/pam.d/greetd" "${ROOT}/etc/pam.d/greetd.bak.noctalia.20260101000000"
exit 0
EOF
	chmod +x "${ROOT}/usr/share/noctalia-greeter/setup_greetd_pam.sh"
	printf 'session    include     postlogin\n' >"${ROOT}/etc/pam.d/greetd"

	# Line 1 is excluded so the shebang keeps pointing at the real /usr/bin/env.
	# Both forms matter: mid-line, and a bare command at column 0.
	sed -e "s#/ctx/#${CTX}/#g" \
		-e "1!s#^\\(/etc/\\|/usr/\\)#${ROOT}\\1#" \
		-e "1!s#\\([^[:alnum:]_.-]\\)/etc/#\\1${ROOT}/etc/#g" \
		-e "1!s#\\([^[:alnum:]_.-]\\)/usr/#\\1${ROOT}/usr/#g" \
		"${BUILD_SRC}" >"${SCRIPT}"

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SYSTEMCTL_LOG RPM_LOG NIRI_LOG NOCTALIA_LOG CURL_LOG

	# curl writes the key the script fingerprints; gpg reports the pinned one.
	# TERRA_FINGERPRINT lets a test make them disagree.
	: "${TERRA_FINGERPRINT:=AE09157A4DE88B497EA1D5D300CDAB43DE226D6F}"
	export TERRA_FINGERPRINT
	cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "${out}" ]] && printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n' > "${out}"
exit 0
EOF
	chmod +x "${STUB_BIN}/curl"
	cat >"${STUB_BIN}/gpg" <<'EOF'
#!/usr/bin/bash
printf 'fpr:::::::::%s:\n' "${TERRA_FINGERPRINT}"
exit 0
EOF
	chmod +x "${STUB_BIN}/gpg"

	for tool in dnf5 systemctl rpm niri noctalia; do
		local log_var
		log_var="$(printf '%s' "${tool}" | tr '[:lower:]' '[:upper:]')_LOG"
		cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "\${${log_var}}"
exit 0
EOF
		chmod +x "${STUB_BIN}/${tool}"
	done
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

@test "60-niri-noctalia: sandbox rewrite left no writes to the real filesystem" {
	# Guards the rewrite: an unmatched path would edit the host for real.
	run grep -nE '(^|[^-[:alnum:]])/ctx/' "${SCRIPT}"
	[ "$status" -ne 0 ]

	run grep -nE '(^|[^[:alnum:]_.-])(/etc|/usr)/' <(tail -n +2 "${SCRIPT}")
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: completes successfully" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "60-niri-noctalia: emits GitHub Actions group markers" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"::group:: Install niri and Noctalia"* ]]
	[[ "$output" == *"::group:: Remove GNOME"* ]]
	[[ "$output" == *"::group:: Verify the desktop is coherent"* ]]
	[[ "$output" == *"::group:: Install the greeter"* ]]
	[[ "$output" == *"::group:: Configure and enable the greeter"* ]]
	[[ "$output" == *"::endgroup::"* ]]
}

@test "60-niri-noctalia: installs the compositor, the shell and its Xwayland bridge together" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# Weak deps are off, so each has to be named: no xwayland-satellite means
	# no X11 apps, no noctalia means no bar, launcher or lock screen.
	grep -qE '^install -y niri xwayland-satellite noctalia sound-theme-freedesktop$' "${DNF5_LOG}"
}

@test "60-niri-noctalia: installs Ghostty from its COPR in isolation" {
	# The COPR must be enabled for the transaction only, never in the image.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx -- '-y copr enable scottames/ghostty' "${DNF5_LOG}"
	grep -qx -- '-y copr disable scottames/ghostty' "${DNF5_LOG}"
	grep -qx -- '-y install --enablerepo=copr:copr.fedorainfracloud.org:scottames:ghostty ghostty' "${DNF5_LOG}"
}

@test "60-niri-noctalia: removes the GNOME session and the greeter that depends on it" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# gdm cannot be kept, and a surviving -session package would keep
	# advertising a session that can no longer start.
	local removal
	removal="$(grep -E '^remove -y ' "${DNF5_LOG}")"
	for package in gnome-shell mutter gnome-session gnome-session-wayland-session \
		gnome-classic-session gdm; do
		[[ "${removal}" == *" ${package} "* || "${removal}" == *" ${package}" ]] || {
			echo "not removed: ${package}" >&2
			return 1
		}
	done
}

@test "60-niri-noctalia: keeps the packages the niri session still needs" {
	# These survive the GNOME removal and are named by the config and the
	# portal file. A wider removal list must not quietly take them.
	local removal
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	removal="$(grep -E '^remove -y ' "${DNF5_LOG}")"
	for package in nautilus gnome-keyring xdg-desktop-portal-gtk xdg-desktop-portal-gnome; do
		[[ "${removal}" != *"${package}"* ]] || {
			echo "removed a package the session needs: ${package}" >&2
			return 1
		}
	done
}

@test "60-niri-noctalia: fails when no niri session entry survives" {
	rm -f "${ROOT}/usr/share/wayland-sessions/niri.desktop"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: fails when a GNOME session entry survives" {
	# A session file whose compositor was removed is a login that dead-ends.
	printf '[Desktop Entry]\nName=GNOME\n' \
		>"${ROOT}/usr/share/wayland-sessions/gnome.desktop"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: fails when niri's portal configuration is missing" {
	rm -f "${ROOT}/usr/share/xdg-desktop-portal/niri-portals.conf"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: validates the shipped niri configuration" {
	# custom/files put the config in place during the overlay phase; this is
	# the only point in the build where a compositor exists to check it.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx "validate --config ${ROOT}/etc/niri/config.kdl" "${NIRI_LOG}"
}

@test "60-niri-noctalia: fails when niri rejects the shipped configuration" {
	cat >"${STUB_BIN}/niri" <<'EOF'
#!/usr/bin/bash
exit 1
EOF
	chmod +x "${STUB_BIN}/niri"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: asserts the Noctalia binary is present and named as expected" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx -- '--version' "${NOCTALIA_LOG}"
}

@test "60-niri-noctalia: installs the greeter and greetd together" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# greetd is the display manager; noctalia-greeter is the greeter it runs.
	grep -qx 'install -y greetd noctalia-greeter' "${DNF5_LOG}"
}

@test "60-niri-noctalia: restricts Terra to the greeter alone" {
	# Terra's own noctalia is older than Fedora's; unrestricted, it could
	# downgrade the shell out from under the session.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# The file is written, used, then removed: assert on the script's content.
	grep -q 'includepkgs=noctalia-greeter' <(sed -n '/^\[terra\]/,/^EOF$/p' "${SCRIPT}")
	grep -q 'gpgcheck=1' <(sed -n '/^\[terra\]/,/^EOF$/p' "${SCRIPT}")
}

@test "60-niri-noctalia: leaves no third-party repository behind" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# A build-time source only; an enabled Terra would outlive the build.
	[ ! -e "${ROOT}/etc/yum.repos.d/terra.repo" ]
}

@test "60-niri-noctalia: pins Terra's signing key by fingerprint" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# No .repo file to inherit, so the key is checked, not trusted on sight.
	grep -q 'repos.fyralabs.com/terra44/key.asc' "${CURL_LOG}"
	grep -q 'proto =https' "${CURL_LOG}"
}

@test "60-niri-noctalia: fails when Terra's key does not match the pin" {
	TERRA_FINGERPRINT="0000000000000000000000000000000000000000"
	export TERRA_FINGERPRINT

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"fingerprint mismatch"* ]]
}

@test "60-niri-noctalia: fails on a Fedora release whose key is not pinned" {
	# Each Fedora release gets a different key, so a rebase stops for a human.
	sed -i 's/^VERSION_ID=44$/VERSION_ID=99/' "${ROOT}/usr/lib/os-release"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"no pinned Terra signing key for Fedora 99"* ]]
}

@test "60-niri-noctalia: fails when the greeter's session wrapper is missing" {
	# The wrapper starts the bundled compositor the greeter draws inside.
	rm -f "${ROOT}/usr/bin/noctalia-greeter-session"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: fails when the greeter's bundled compositor is missing" {
	rm -f "${ROOT}/usr/bin/noctalia-greeter-compositor"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: fails when the greeter's runtime assets are missing" {
	# Without it the greeter starts with no fonts, icons or UI.
	rm -rf "${ROOT}/usr/share/noctalia-greeter/assets"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: fails when the appearance-sync Polkit action is missing" {
	# Without it `greeter-sync` cannot apply the session's theme.
	rm -f "${ROOT}/usr/share/polkit-1/actions/org.noctalia.greeter.apply-appearance.policy"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: points greetd at the session wrapper as greetd's own user" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local config="${ROOT}/etc/greetd/config.toml"
	[ -f "${config}" ]
	# The rewrite reaches inside the heredoc, so the generated file carries a
	# prefixed path; the real one comes from the script.
	grep -qE '^command = ".*/noctalia-greeter-session"$' "${config}"
	grep -qx 'command = "/usr/bin/noctalia-greeter-session"' "${BUILD_SRC}"
	# greetd already creates this account; upstream's `greeter` would duplicate it.
	grep -qx 'user = "greetd"' "${config}"
	grep -qx 'vt = 1' "${config}"
}

@test "60-niri-noctalia: gives greetd's PAM stack a logind session" {
	# The greeter needs a logind session to reach the seat's devices.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -q 'pam_systemd.so' "${ROOT}/etc/pam.d/greetd"
}

@test "60-niri-noctalia: fails when the PAM helper does not add the session line" {
	printf '#!/usr/bin/bash\nexit 0\n' \
		>"${ROOT}/usr/share/noctalia-greeter/setup_greetd_pam.sh"
	chmod +x "${ROOT}/usr/share/noctalia-greeter/setup_greetd_pam.sh"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: ships no PAM backup in the image" {
	# The helper leaves a timestamped copy with nothing to restore.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	run compgen -G "${ROOT}/etc/pam.d/greetd.bak.noctalia.*"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: enables the unit that creates the greeter's state directory" {
	# 90-cleanup.sh prunes /var, so the directory is made on the booted machine.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'enable noctalia-greeter-setup.service' "${SYSTEMCTL_LOG}"
}

@test "60-niri-noctalia: the state-directory unit is ordered before greetd" {
	local unit="${REPO_ROOT}/custom/files/usr/lib/systemd/system/noctalia-greeter-setup.service"
	[ -f "${unit}" ]

	grep -qx 'Before=greetd.service' "${unit}"
	grep -qx 'Type=oneshot' "${unit}"
	grep -qx 'WantedBy=graphical.target' "${unit}"
	# The helper would otherwise guess from an owner that does not exist yet.
	grep -qx 'Environment=GREETER_USER=greetd' "${unit}"
}

@test "60-niri-noctalia: the unit names the same greeter account as greetd's config" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local unit="${REPO_ROOT}/custom/files/usr/lib/systemd/system/noctalia-greeter-setup.service"
	local unit_user config_user
	unit_user="$(sed -nE 's/^Environment=GREETER_USER=(.+)$/\1/p' "${unit}")"
	config_user="$(sed -nE 's/^user = "(.+)"$/\1/p' "${ROOT}/etc/greetd/config.toml")"
	[ -n "${unit_user}" ]
	[ "${unit_user}" = "${config_user}" ]
}

@test "60-niri-noctalia: clears the dangling display-manager alias before enabling greetd" {
	# systemctl will not replace an existing symlink, so a dangling alias from
	# gdm would boot to no greeter at all.
	[ -L "${ROOT}/etc/systemd/system/display-manager.service" ]

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ ! -e "${ROOT}/etc/systemd/system/display-manager.service" ]
	[ ! -L "${ROOT}/etc/systemd/system/display-manager.service" ]
	grep -qx 'enable greetd.service' "${SYSTEMCTL_LOG}"
	grep -qx 'set-default graphical.target' "${SYSTEMCTL_LOG}"
}

@test "60-niri-noctalia: records the desktop as the os-release variant exactly once" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local os_release="${ROOT}/usr/lib/os-release"
	[ "$(grep -c '^VARIANT=' "${os_release}")" -eq 1 ]
	[ "$(grep -c '^VARIANT_ID=' "${os_release}")" -eq 1 ]
	grep -qx 'VARIANT="Niri"' "${os_release}"
	grep -qx 'VARIANT_ID=niri' "${os_release}"
	# The identity 00-image-info.sh wrote is not disturbed.
	grep -qx 'ID=noctiri' "${os_release}"
}

@test "60-niri-noctalia: rewriting the variant is idempotent across a rebuild" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ "$(grep -c '^VARIANT=' "${ROOT}/usr/lib/os-release")" -eq 1 ]
}

@test "60-niri-noctalia: sources copr-helpers.sh so copr_install_isolated is available" {
	cat >>"${SCRIPT}" <<'EOF'
declare -F copr_install_isolated >/dev/null && echo "HELPER_PRESENT"
EOF
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"HELPER_PRESENT"* ]]
}

@test "60-niri-noctalia: fails fast when copr-helpers.sh is missing from the context" {
	rm -f "${CTX}/build/copr-helpers.sh"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "60-niri-noctalia: restores default glob behaviour before finishing" {
	cat >>"${SCRIPT}" <<'EOF'
shopt -q nullglob || echo "NULLGLOB_OFF"
EOF
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"NULLGLOB_OFF"* ]]
}
