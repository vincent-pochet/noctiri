#!/usr/bin/env bats
# Contract: the session ships an authentication agent of its own.
#
# build/60-niri-noctalia.sh removes gnome-shell, which was the system's only
# Polkit authentication agent, and niri starts none in its place. polkitd keeps
# deciding, but with nothing registered to ask for a password pkexec falls back
# to its textual agent and dies looking for a /dev/tty no graphical caller has.
# `noctalia msg greeter-sync` and nm-connection-editor saving a system
# connection are the two this image ships into that.
#
# The two files below cannot read each other: one removes the old agent, the
# other turns on Noctalia's. Nothing but this test keeps them in agreement.
#
# Run with: bats tests/contract/polkit-agent_test.bats

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
DESKTOP_SCRIPT="${REPO_ROOT}/build/60-niri-noctalia.sh"
POLKIT_CONFIG="${REPO_ROOT}/custom/config/noctalia/20-polkit-agent.toml"

@test "the desktop build still removes the agent GNOME supplied" {
    # The premise. A fork that stops removing gnome-shell makes the rest of
    # this file moot, and should be reading a failure here rather than
    # carrying a default nothing explains.
    grep -qE '^\s*gnome-shell\s*\\?$' "${DESKTOP_SCRIPT}"
}

@test "the seeded Noctalia defaults turn the built-in agent on" {
    [ -f "${POLKIT_CONFIG}" ]
    grep -qx '\[shell\]' "${POLKIT_CONFIG}"
    grep -qE '^polkit_agent[[:space:]]*=[[:space:]]*true$' "${POLKIT_CONFIG}"
}

@test "no other seeded default turns it back off" {
    # Noctalia merges every *.toml in the directory, so a later file wins.
    run grep -rlE '^polkit_agent[[:space:]]*=[[:space:]]*false' \
        "${REPO_ROOT}/custom/config/noctalia"
    [ "${status}" -ne 0 ]
}
