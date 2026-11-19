#!/usr/bin/env bats
# Contract: Qt applications on the KDE runtime get the same fonts as GTK.
#
# custom/config/kdeglobals is read by KDE-runtime Flatpaks such as VLC. The
# KDE 5.15 runtime only parses the 10-field Qt 5 font string, and a string it
# cannot parse silently falls back to Noto Sans 10.
#
# Run with: bats tests/contract/kdeglobals-fonts_test.bats

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
KDEGLOBALS="${REPO_ROOT}/custom/config/kdeglobals"
FONT_KEYS=(font menuFont smallestReadableFont toolBarFont fixed)

@test "every font key is set under [General]" {
    [ -f "${KDEGLOBALS}" ]
    general="$(sed -n '/^\[General\]$/,/^\[/p' "${KDEGLOBALS}")"
    for key in "${FONT_KEYS[@]}"; do
        grep -qE "^${key}=" <<<"${general}"
    done
}

@test "every font uses the 10-field Qt 5 string" {
    for key in "${FONT_KEYS[@]}"; do
        value="$(sed -n "s/^${key}=//p" "${KDEGLOBALS}")"
        [ "$(awk -F, '{print NF}' <<<"${value}")" -eq 10 ]
    done
}

@test "the families match the GTK defaults of the base image" {
    grep -qx 'font=Adwaita Sans,11,.*' "${KDEGLOBALS}"
    grep -qx 'fixed=JetBrains Mono,11,.*' "${KDEGLOBALS}"
}
