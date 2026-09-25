# vim: set ft=make :
#######################
### custom-system.just
#######################
## System-level commands.
##
## Nothing here runs automatically: image updates and logins never overwrite
## user configuration or change group membership. These recipes are the
## explicit, user-invoked way to do both.

# Add the current user to the docker and libvirt groups, creating them if needed.
[group('System')]
configure-dev-groups:
    #!/usr/bin/env bash
    set -euo pipefail

    # Fedora ships no /usr/lib/group entry to copy for either name, and both
    # daemons are opt-in for a fork, so create a group when it is missing rather
    # than assume a package provided it. Only the mutating commands escalate;
    # the checks run as the invoking user.
    CURRENT_USER="$(id -un)"
    DEV_GROUPS=(docker libvirt)
    MISSING=()

    for group in "${DEV_GROUPS[@]}"; do
        if ! getent group "${group}" >/dev/null; then
            echo "Creating the ${group} group"
            sudo groupadd --system "${group}"
        fi
        if ! id -nG "${CURRENT_USER}" | grep -qw "${group}"; then
            MISSING+=("${group}")
        fi
    done

    if ((${#MISSING[@]} == 0)); then
        echo "${CURRENT_USER} is already in: ${DEV_GROUPS[*]}"
        exit 0
    fi

    if command -v gum >/dev/null 2>&1; then
        if ! gum confirm "Add ${CURRENT_USER} to: ${MISSING[*]}?"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    GROUP_LIST="$(IFS=,; echo "${MISSING[*]}")"
    sudo usermod --append --groups "${GROUP_LIST}" "${CURRENT_USER}"
    echo "Added ${CURRENT_USER} to: ${MISSING[*]}"
    echo "Log out and back in before using docker or libvirt without sudo."

# Restore the image's default user configuration into this user's home.
[group('System')]
install-config:
    #!/usr/bin/env bash
    set -euo pipefail

    # The defaults live in /etc/skel/.config, which covers every account created
    # after the build. An existing user's own files always win: nothing applies
    # them on login or on an image update, so this is the explicit way to get
    # them back. Files it replaces are backed up beside the original.
    SKEL_CONFIG="${SKEL_CONFIG:-/etc/skel/.config}"
    USER_CONFIG="${USER_CONFIG:-${HOME}/.config}"
    TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"

    bold="$(tput bold 2>/dev/null || printf '\033[1m')"
    normal="$(tput sgr0 2>/dev/null || printf '\033[0m')"

    if [[ ! -d "${SKEL_CONFIG}" ]]; then
        echo "Error: ${SKEL_CONFIG} does not exist" >&2
        exit 1
    fi

    # Collect conflicts first, so the prompt shows the full set before anything
    # is touched.
    conflicts=()
    while IFS= read -r -d '' file; do
        relative="${file#"${SKEL_CONFIG}"/}"
        target="${USER_CONFIG}/${relative}"
        if [[ -e "${target}" || -L "${target}" ]]; then
            conflicts+=("${relative}")
        fi
    done < <(find "${SKEL_CONFIG}" -type f -print0)

    echo "${bold}Re-apply default configuration${normal}"
    echo "  from: ${SKEL_CONFIG}"
    echo "    to: ${USER_CONFIG}"
    if ((${#conflicts[@]})); then
        echo
        echo "Already present, and will be backed up first:"
        printf '  - %s\n' "${conflicts[@]}"
    fi
    echo

    if command -v gum >/dev/null 2>&1; then
        if ! gum confirm "Apply these defaults?"; then
            echo "Cancelled."
            exit 0
        fi
    fi

    backed_up=()
    installed=()
    while IFS= read -r -d '' file; do
        relative="${file#"${SKEL_CONFIG}"/}"
        target="${USER_CONFIG}/${relative}"
        target_dir="$(dirname "${target}")"

        if ! mkdir -p "${target_dir}"; then
            echo "  WARN: cannot create ${target_dir}, skipping ${relative}"
            continue
        fi

        if [[ -e "${target}" || -L "${target}" ]]; then
            backup="${target}.backup.${TIMESTAMP}"
            n=1
            while [[ -e "${backup}" || -L "${backup}" ]]; do
                backup="${target}.backup.${TIMESTAMP}.${n}"
                n=$((n + 1))
            done
            mv "${target}" "${backup}"
            backed_up+=("${relative}")
        fi

        cp "${file}" "${target}"
        installed+=("${relative}")
    done < <(find "${SKEL_CONFIG}" -type f -print0)

    echo
    echo "${bold}Applied ${#installed[@]} file(s)${normal}"
    if ((${#backed_up[@]})); then
        echo
        echo "Backed up:"
        for entry in "${backed_up[@]}"; do
            echo "  - ${entry}.backup.${TIMESTAMP}"
        done
    fi

# Copy the image's niri configuration into this user's home, so it can be edited.
[group('Desktop')]
niri-edit-config:
    #!/usr/bin/env bash
    set -euo pipefail

    # niri reads ~/.config/niri/config.kdl first and /etc/niri/config.kdl only
    # as a fallback. Editing the image's copy is the wrong move: /etc is
    # three-way merged on every image update. Reverting is deleting the copy.
    SYSTEM_CONFIG=/etc/niri/config.kdl
    USER_CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/niri/config.kdl"

    if [[ ! -f "${SYSTEM_CONFIG}" ]]; then
        echo "No ${SYSTEM_CONFIG}: this image does not ship a niri configuration."
        exit 1
    fi

    if [[ -e "${USER_CONFIG}" ]]; then
        echo "Editing your existing ${USER_CONFIG}"
    else
        mkdir -p "$(dirname "${USER_CONFIG}")"
        cp "${SYSTEM_CONFIG}" "${USER_CONFIG}"
        echo "Copied ${SYSTEM_CONFIG} to ${USER_CONFIG}"
    fi

    "${EDITOR:-nano}" "${USER_CONFIG}"

    # niri applies a valid config on write and keeps the previous one otherwise.
    if niri validate --config "${USER_CONFIG}"; then
        echo "Configuration is valid; niri has already reloaded it."
    else
        echo "Configuration is invalid. niri kept the last good one; fix it and save again."
        exit 1
    fi
