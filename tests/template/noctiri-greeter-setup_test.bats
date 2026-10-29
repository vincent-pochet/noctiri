#!/usr/bin/env bats
# Unit tests for custom/files/usr/libexec/noctiri-greeter-setup.sh.
#
# The script's whole job is to make the login screen agree with the machine.
# Getting the keyboard layout wrong there does not look like a bug: it looks
# like the user typing the wrong password, and greetd reports it as a PAM
# AUTH_ERR. So the layout cases are the bulk of what is asserted here.
#
# Every path the script touches is overridable, so no test needs root or /var.
#
# Run with: bats tests/template/noctiri-greeter-setup_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/custom/files/usr/libexec/noctiri-greeter-setup.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/greeter-setup.${BATS_TEST_NUMBER:-0}.$$"
	STATE_DIR="${TEST_ROOT}/state"
	GREETER_TOML="${STATE_DIR}/greeter.toml"
	VCONSOLE_CONF="${TEST_ROOT}/vconsole.conf"
	XORG_KEYBOARD_CONF="${TEST_ROOT}/00-keyboard.conf"
	APPLY_APPEARANCE="${TEST_ROOT}/apply-appearance"

	mkdir -p "${TEST_ROOT}"

	# Stands in for noctalia-greeter-apply-appearance --setup-system, which
	# writes a greeter.toml of nothing but schema comments -- no [keyboard].
	cat >"${APPLY_APPEARANCE}" <<EOF
#!/usr/bin/env bash
mkdir -p "${STATE_DIR}"
cat >"${GREETER_TOML}" <<'TOML'
# noctalia-greeter greeter.toml (declarative)
# [keyboard] layout/variant/options/numlock
TOML
exit 0
EOF
	chmod +x "${APPLY_APPEARANCE}"

	# chown to a real account the test user owns, so the script's final step is
	# exercised rather than skipped.
	export GREETER_USER="$(id -un)"
	export NOCTALIA_GREETER_STATE_DIR="${STATE_DIR}"
	export VCONSOLE_CONF XORG_KEYBOARD_CONF APPLY_APPEARANCE
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

keyboard_section() {
	sed -n '/^\[keyboard\]$/,$p' "${GREETER_TOML}"
}

@test "greeter-setup: creates greeter.toml when the state directory is empty" {
	printf 'XKBLAYOUT=ch\n' >"${VCONSOLE_CONF}"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[ -f "${GREETER_TOML}" ]
}

@test "greeter-setup: writes the machine's layout, variant and options" {
	printf 'KEYMAP=ch-fr\nXKBLAYOUT=ch\nXKBVARIANT=fr\nXKBOPTIONS=terminate:ctrl_alt_bksp\n' \
		>"${VCONSOLE_CONF}"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	run keyboard_section
	[[ "$output" == *'layout = "ch"'* ]]
	[[ "$output" == *'variant = "fr"'* ]]
	[[ "$output" == *'options = "terminate:ctrl_alt_bksp"'* ]]
}

@test "greeter-setup: omits variant and options when localed has none" {
	printf 'XKBLAYOUT=de\n' >"${VCONSOLE_CONF}"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'layout = "de"' "${GREETER_TOML}"
	# An empty string is a value, not an absence: it would pin the greeter to a
	# variant rather than leave the layout's default in place.
	! grep -q 'variant = ""' "${GREETER_TOML}"
	! grep -q 'options = ""' "${GREETER_TOML}"
}

@test "greeter-setup: unquotes values systemd-firstboot wrote with quotes" {
	printf 'XKBLAYOUT="ch"\nXKBVARIANT="fr"\n' >"${VCONSOLE_CONF}"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'layout = "ch"' "${GREETER_TOML}"
	grep -qx 'variant = "fr"' "${GREETER_TOML}"
}

@test "greeter-setup: falls back to Xorg's snippet when vconsole has no keymap" {
	# systemd-localed writes both; older releases wrote only the Xorg one.
	printf 'KEYMAP=ch-fr\nFONT=eurlatgr\n' >"${VCONSOLE_CONF}"
	cat >"${XORG_KEYBOARD_CONF}" <<'EOF'
Section "InputClass"
	Identifier "system-keyboard"
	MatchIsKeyboard "on"
	Option "XkbLayout" "ch"
	Option "XkbVariant" "fr"
EndSection
EOF

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'layout = "ch"' "${GREETER_TOML}"
	grep -qx 'variant = "fr"' "${GREETER_TOML}"
}

@test "greeter-setup: leaves the layout alone when the machine configures none" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ -f "${GREETER_TOML}" ]
	# Writing layout = "" would pin the greeter to the default rather than
	# leave the greeter free to pick it.
	! grep -q '^\[keyboard\]$' "${GREETER_TOML}"
}

@test "greeter-setup: a second boot does not stack a second [keyboard] section" {
	printf 'XKBLAYOUT=ch\nXKBVARIANT=fr\n' >"${VCONSOLE_CONF}"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ "$(grep -c '^\[keyboard\]$' "${GREETER_TOML}")" -eq 1 ]
}

@test "greeter-setup: a changed keymap replaces the old layout rather than adding one" {
	printf 'XKBLAYOUT=ch\nXKBVARIANT=fr\nXKBOPTIONS=compose:ralt\n' >"${VCONSOLE_CONF}"
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	printf 'XKBLAYOUT=fr\nXKBVARIANT=oss\n' >"${VCONSOLE_CONF}"
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'layout = "fr"' "${GREETER_TOML}"
	grep -qx 'variant = "oss"' "${GREETER_TOML}"
	! grep -q '"ch"' "${GREETER_TOML}"
	# The options key is owned by this script, so an unset one must go away
	# rather than survive from the previous keymap.
	! grep -q 'compose:ralt' "${GREETER_TOML}"
}

@test "greeter-setup: keeps keys of [keyboard] it does not own" {
	printf 'XKBLAYOUT=ch\n' >"${VCONSOLE_CONF}"
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# greeter.toml is documented as hand-editable, so numlock is the user's.
	printf 'numlock = true\n' >>"${GREETER_TOML}"

	printf 'XKBLAYOUT=fr\n' >"${VCONSOLE_CONF}"
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'numlock = true' "${GREETER_TOML}"
	grep -qx 'layout = "fr"' "${GREETER_TOML}"
	[ "$(grep -c '^numlock = true$' "${GREETER_TOML}")" -eq 1 ]
}

@test "greeter-setup: leaves other tables untouched" {
	printf 'XKBLAYOUT=ch\n' >"${VCONSOLE_CONF}"
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	printf '\n[appearance]\nscheme = "Noctalia"\n\n[idle]\ntimeout = 300\n' >>"${GREETER_TOML}"
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'scheme = "Noctalia"' "${GREETER_TOML}"
	grep -qx 'timeout = 300' "${GREETER_TOML}"
}

@test "greeter-setup: fails when the vendor helper writes no greeter.toml" {
	# Silently carrying on would boot to a greeter with no state at all.
	printf '#!/usr/bin/env bash\nexit 0\n' >"${APPLY_APPEARANCE}"
	chmod +x "${APPLY_APPEARANCE}"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"did not create"* ]]
}
