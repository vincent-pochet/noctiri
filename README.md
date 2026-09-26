# Noctiri

A bootc operating system based on
[Bluefin DX](https://docs.projectbluefin.io/bluefin-dx/), running the
[niri](https://github.com/niri-wm/niri) scrolling Wayland compositor and the
[Noctalia](https://github.com/noctalia-dev/noctalia) shell.

## What makes this different from Bluefin DX

This image is `ghcr.io/ublue-os/bluefin-dx:stable` with its own session. It
keeps everything Bluefin puts *around* the desktop — the `ujust` recipes, the
Homebrew and Flatpak plumbing, `uupd`'s update policy, the codec and hardware
enablement, Bazaar — and runs niri and Noctalia on top of it.

### The developer tooling

`-dx` is Bluefin's developer-experience variant, and this image carries its
container and toolchain half: Docker CE with the Compose and Buildx plugins,
the Podman extras (`podman-compose`, `podman-tui`), the tracing and debugging
tools (`bpftrace`, `bcc`, `sysprof`, `gdb`, `strace`), LLVM/Clang, ROCm,
`kernel-devel`, `flatpak-builder`, `git-lfs` and the devcontainer plumbing.

Before using Docker without `sudo`:

```bash
ujust configure-dev-groups
```

Podman and Docker are the whole of it, and the editor is Zed. Cross-architecture
container builds work as they do on stock Bluefin — `qemu-user-static-aarch64`
stays, and its `binfmt_misc` registration uses the `F` flag, so

```bash
podman build --platform=linux/arm64 .
```

needs nothing mounted into the container. Two build phases say what left, which
is worth reading before wondering where something went:
[`build/70-remove-virtualization.sh`](build/70-remove-virtualization.sh) takes
out the host virtualization stack, and
[`build/75-remove-base-apps.sh`](build/75-remove-base-apps.sh) the applications
this image replaces. The session itself is assembled in
[`build/60-niri-noctalia.sh`](build/60-niri-noctalia.sh).

### Added packages (build-time)

The desktop, all from Fedora's own repositories:

- **niri** — the scrolling-tiling Wayland compositor, with
  **xwayland-satellite**
- **noctalia** — the shell: bar, dock, launcher, notifications, control centre,
  wallpaper, clipboard history, lock screen and settings UI, in one binary
- **noctalia-greeter** and **greetd** — the login screen, from the same project
  as the shell (see [The greeter](#the-greeter)). The greeter is the one package
  not from Fedora: it comes from [Terra](https://terrapkg.com), added for that
  one transaction and removed again

Applications and the utilities the session calls:

- **ghostty** — the terminal, from the `scottames/ghostty` COPR, installed
  isolated so the repository is not left enabled in the image
- **nautilus** — the file manager, inherited from Bluefin and kept explicitly
- **gnome-keyring**, **gnome-keyring-pam** — Secret Service, unlocked at login
- **upower**, **ddcutil** — battery readings, and brightness on external
  monitors over DDC/CI
- **grim**, **slurp**, **wl-clipboard**, **brightnessctl**, **playerctl** —
  capture, region selection, clipboard, backlight and MPRIS control
- **sound-theme-freedesktop** — Noctalia's event sounds

The build sets `install_weak_deps=0`, so nothing arrives by `Recommends`:
every one of these is named on purpose.

### Applications (first boot)

Declared in [`custom/flatpaks/`](custom/flatpaks/default.preinstall) and
installed by `flatpak preinstall` the first time the system boots with a
network connection:

- **Zed** (`dev.zed.Zed`) — the editor, from the build its own project
  publishes on Flathub
- **Thunderbird**, **Flatseal**, **Extension Manager**

### Configuration changes

- `/etc/niri/config.kdl` — the image's niri configuration, shipped through
  [`custom/files/`](custom/files/etc/niri/config.kdl) and validated by
  `niri validate` during the build, so a broken config fails CI rather than
  your first login
- `/etc/greetd/config.toml` — greetd runs `noctalia-greeter-session` as
  greetd's own service account
- `/etc/pam.d/greetd` — a required `pam_systemd.so` session line, so the
  greeter gets the logind session it needs to reach the seat
- `noctalia-greeter-setup.service` — creates `/var/lib/noctalia-greeter` on
  first boot, because `90-cleanup.sh` prunes `/var` out of the image
- `display-manager.service` now points at `greetd`
- `os-release` carries `VARIANT="Niri"` / `VARIANT_ID=niri`

No portal configuration is shipped: niri's own
`/usr/share/xdg-desktop-portal/niri-portals.conf` already names the backends it
wants — `xdg-desktop-portal-gnome` for screencasting, since niri speaks the
same ScreenCast D-Bus API, `xdg-desktop-portal-gtk` for the file chooser and
notifications, and `gnome-keyring` for secrets. The build asserts those three
are installed.

## The desktop

Noctalia supplies the bar, launcher, notifications, lock screen, wallpaper and
settings; niri supplies the window management. The binds below are the ones
that differ from stock niri. `Mod` is <kbd>Super</kbd>.

| Bind | Does |
|---|---|
| <kbd>Mod</kbd>+<kbd>T</kbd> | Ghostty |
| <kbd>Mod</kbd>+<kbd>E</kbd> | Files |
| <kbd>Mod</kbd>+<kbd>D</kbd> / <kbd>Mod</kbd>+<kbd>Space</kbd> | Noctalia launcher |
| <kbd>Mod</kbd>+<kbd>S</kbd> | Noctalia control centre |
| <kbd>Mod</kbd>+<kbd>N</kbd> | Notification history |
| <kbd>Mod</kbd>+<kbd>,</kbd> | Noctalia settings |
| <kbd>Mod</kbd>+<kbd>Alt</kbd>+<kbd>L</kbd> | Lock the screen |
| <kbd>Mod</kbd>+<kbd>Alt</kbd>+<kbd>V</kbd> | Clipboard history |
| <kbd>Mod</kbd>+<kbd>Shift</kbd>+<kbd>Print</kbd> | Noctalia screenshot, with annotation |
| <kbd>Mod</kbd>+<kbd>Shift</kbd>+<kbd>/</kbd> | niri's hotkey overlay — everything else |

Volume, microphone, media and brightness keys route through Noctalia so its
on-screen display shows the change. Everything not listed is stock niri; press
<kbd>Mod</kbd>+<kbd>Shift</kbd>+<kbd>/</kbd> for the full list.

To change any of it:

```bash
ujust niri-edit-config
```

That copies `/etc/niri/config.kdl` into `~/.config/niri/config.kdl`, opens your
`$EDITOR`, and validates the result. niri reloads a valid config as soon as it
is written and keeps the last good one when it is not. Edit the copy, never
`/etc`: `/etc` is three-way merged on every image update.

### The greeter

niri has no bundled greeter of its own, so the image picks one.

It uses **[Noctalia Greeter](https://github.com/noctalia-dev/noctalia-greeter)** —
the login screen built by the same project as the shell, so the greeter and the
session share a visual language rather than merely coexisting.

It is a **greetd** greeter, so greetd is the display manager: greetd runs
`noctalia-greeter-session`, which starts the greeter's own bundled wlroots
compositor and draws the greeter inside it. It reads
`/usr/share/wayland-sessions`, so niri appears in its session picker with no
extra wiring.

#### Theming it

The greeter reads `/var/lib/noctalia-greeter/greeter.toml`, whose own header
documents every key it takes — `[appearance]` (colour scheme, password style,
corner radius, font), `[appearance.palette]` for the full colour-role table,
`[appearance.wallpaper]`, plus `[output]`, `[keyboard]`, `[idle]` and `[cursor]`.

The easier path is to let the shell drive it:

```bash
noctalia msg greeter-sync
```

That pushes the session's current wallpaper and colour palette to the greeter,
so the login screen matches whatever theme you are running. It goes through the
Polkit action the greeter package installs, so it prompts once rather than
needing a root shell.

`noctalia-greeter-setup.service` creates that state directory and its default
`greeter.toml` the first time the machine boots. It has to happen there rather
than at build time: `build/90-cleanup.sh` prunes `/var`, so nothing written
under it during the build survives into the shipped image.

#### On the Terra dependency

`noctalia-greeter` is the only package in this image that does not come from
Fedora — it is not packaged there, and upstream's installation guide points
Fedora users at [Terra](https://terrapkg.com). The build adds Terra for that one
transaction and removes the repository file again, with two restrictions worth
knowing about:

- `includepkgs=noctalia-greeter`. Terra also carries `noctalia`,
  `noctalia-nightly`, `noctalia-qs` and `noctalia-legacy`, and its `noctalia` is
  older than the 5.1.0 this image takes from Fedora. Without the restriction,
  Terra would be free to downgrade the shell.
- The signing key is pinned by fingerprint. Terra publishes no `.repo` file to
  inherit, and signs each Fedora release with a **different** key — so the pin
  is per Fedora major, and a Fedora rebase fails the build until someone
  verifies the new key and adds it to `TERRA_KEY_FINGERPRINTS` in
  `build/60-niri-noctalia.sh`. A rotated trust root should be a decision, not a
  silent fetch.

## What's included

**Build system**

- A build on every push to `main`, publishing `:stable-testing`
- Renovate through `projectbluefin/actions`, updating pinned actions and image
  digests every six hours
- Images older than 90 days pruned automatically
- Pull requests validated for shellcheck, hadolint, Brewfiles, Flatpaks,
  Justfiles, and Renovate config
- Keyless OIDC signing on every published image, enforced at promotion
  ([where the signature is checked](#where-the-signature-is-checked))

**Runtime**

- Homebrew, pre-staged at build time and unpacked on first boot
- Flatpaks declared in `custom/flatpaks/`, installed on first boot
- `ujust` shortcuts for the Brewfiles and for re-applying configuration
- `uupd` for scheduled system updates

## Customize

Pick your base image on the `Containerfile`'s `FROM` line; this image uses
`ghcr.io/ublue-os/bluefin-dx:stable`. That line is the only place the base is
chosen: `just build` reads the image name and the tag from it, and the Fedora
major comes from the base image itself during the build. Move to another base
and the desktop phase and the two removal phases are where it shows: each
verifies what it did, so a mismatch fails the build rather than shipping a
broken image.

Then add to your image:

- **System packages** — `build/20-packages-and-services.sh` ([guide](build/README.md))
- **The desktop** — `build/60-niri-noctalia.sh` and
  `custom/files/etc/niri/config.kdl`
- **CLI tools** — `custom/brew/` ([guide](custom/brew/README.md))
- **GUI apps** — `custom/flatpaks/` ([guide](custom/flatpaks/README.md))
- **Commands** — `custom/ujust/` ([guide](custom/ujust/README.md))

[The `customize` skill](.agents/skills/customize/SKILL.md) decides which of
those a given package belongs in.

## Releases

| Branch   | Image tag         | Audience                       |
| -------- | ----------------- | ------------------------------ |
| `main`   | `:stable-testing` | Testers and release candidates |
| `stable` | `:stable`         | Production                     |

Merging to `main` publishes `:stable-testing`; the promotion PR that follows
publishes `:stable` when merged. Promotion verifies the cosign signature on the
testing image before it reports ready, and refuses to promote at all once `main`
has moved past the commit the promotion PR was built from.

> **Known gap:** the promotion gate checks the digest and the signature only. It
> runs no end-to-end tests, so `release/ready` means "signed and unmodified",
> not "functionally validated".

## Image signing

Images are signed with keyless OIDC via Cosign and GitHub Actions. There is no
key to generate or store.

```bash
cosign verify \
  --certificate-identity-regexp="https://github.com/vincent-pochet/noctiri/.github/workflows/" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/vincent-pochet/noctiri:stable
```

Unsigned images fail the promotion gate, so `main → stable` reports
`release/blocked` until signing is restored.

### Where the signature is checked

**In CI, on the way to `:stable` — and not verified on the device.** The
promotion gate is the only enforcement point. An installed system pulls its
updates over an unverified transport (`image-info.json`'s `image-ref` is
`ostree-unverified-image:docker://…`), so `bootc upgrade` does not check the
cosign signature.

That is a deliberate statement of what the image can actually do, not an
oversight. Device-side verification runs through
`/etc/containers/policy.json`, which matches a keyless Fulcio certificate on
`subjectEmail` only — mandatory and exact. A GitHub Actions certificate
identifies its workflow in a URI SAN and carries no email, so no policy entry
can match it, and the inherited policy's `""` catch-all
(`insecureAcceptAnything`) would accept the image regardless. A signed-looking
`image-ref` here would verify nothing while implying it verified something.

Making updates verify on the device means signing with a key the policy can
name: publish with a cosign keypair, merge a `sigstoreSigned` scope for your
namespace into the inherited policy (with `jq`, during
[`build/10-overlay.sh`](build/10-overlay.sh) — never by shipping a whole
`policy.json` through `custom/files/`, which freezes every scope you inherited),
add a `registries.d` entry with `use-sigstore-attachments: true` for it, and
flip `IMAGE_REF` back to `ostree-image-signed:`. Validate that on a real
install before shipping it: a scope that does not match turns `bootc upgrade`
into a hard refusal. `tests/contract/image-signing_test.bats` holds the two
sides together, so changing one without the other fails the suite.

## Using your image

Switch to a built image:

```bash
sudo bootc switch --transport registry ghcr.io/vincent-pochet/noctiri:stable-testing
sudo systemctl reboot
```

Then, as your user:

```bash
ujust install-default-apps    # Homebrew: the default Brewfile
ujust install-dev-tools       # Homebrew: the development Brewfile
ujust configure-dev-groups    # add yourself to the docker group
ujust install-config          # re-apply the image defaults, backing up yours
ujust niri-edit-config        # copy the niri config into your home and edit it
```

First boot unpacks Homebrew and installs the declared Flatpaks; both need a
network connection. Check them with `systemctl status brew-setup.service` and
`systemctl status flatpak-preinstall.service`.

## Local testing

```bash
just build            # build the container image
just build-qcow2      # build a QCOW2 disk image
just run-vm-qcow2     # boot it in a browser-based VM
just build-iso        # build an installer ISO
just test-unit        # run the test suite
```

## Troubleshooting

[The `troubleshooting` skill](.agents/skills/troubleshooting/SKILL.md) covers
build, CI, and runtime failures symptom-first. The two most common first-boot
surprises:

- **No Flatpaks.** `flatpak-preinstall.service` needs a network connection and
  reports success even when it cannot reach Flathub, so a first boot before
  Wi-Fi is configured installs nothing. Reboot once you are online.
- **No `brew`.** `brew-setup.service` unpacks Homebrew on first boot; check its
  status before reaching for a reinstall.
- **An unfamiliar login screen.** That is Noctalia Greeter: see
  [The greeter](#the-greeter). Log in and niri starts; if it does not,
  `journalctl -b -u greetd` and `journalctl --user -u niri` have the reason.
- **A greeter that does not match your desktop theme.** Run
  `noctalia msg greeter-sync` from the session. If the state directory is
  missing entirely, `systemctl status noctalia-greeter-setup.service` says
  why it did not run.
- **A bar-less, wallpaper-less niri.** Noctalia is started by niri through
  `spawn-at-startup` in `/etc/niri/config.kdl`. A `~/.config/niri/config.kdl`
  copied from an older image, or from upstream niri, will not have that line.

## Community

- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussions](https://github.com/bootc-dev/bootc/discussions)

## Learn more

- [Universal Blue](https://universal-blue.org/)
- [bootc](https://containers.github.io/bootc/)
- [Project Bluefin contributing guide](https://docs.projectbluefin.io/contributing/)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
