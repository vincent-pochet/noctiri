---
name: troubleshooting
description: >-
  Symptom to cause to fix for build, CI, and runtime failures, plus the
  pre-commit checklist. Use when something is broken or before opening a
  pull request.
---

# Troubleshooting

## Before a pull request

- [ ] Conventional Commit message.
- [ ] `just lint` — shellcheck on every tracked script.
- [ ] `just check` — Justfile syntax.
- [ ] `just test-unit` — the suite.
- [ ] `just validate-brewfiles` / `just validate-flatpaks` if those changed.
- [ ] `just build` if the image changed.

CI runs the same checks; running them locally only makes the pull request quiet.

## Build

| Symptom | Cause | Fix |
|---|---|---|
| `bootc container lint` fails on a nonempty `/run` | a script wrote to `/run` into an image layer | remove it in `90-cleanup.sh`; that phase deliberately does not mount `/run` as tmpfs |
| a third-party repository is live in the final image | a script enabled it and did not disable it | use `copr_install_isolated`, or disable it explicitly |
| the package layer rebuilds on every overlay edit | packages drifted into the overlay phase | keep packages in `20-packages-and-services.sh` |
| hadolint flags the Containerfile | a rule in `.github/hadolint.yaml` | fix it, or add a suppression with a reason |

## CI

| Symptom | Cause | Fix |
|---|---|---|
| `validate` never runs | branch protection names a check no workflow produces | the context must be exactly `validate` |
| Renovate logs a skip and opens nothing | `RENOVATE_TOKEN` is not set | expected; set the secret to turn Renovate on |
| Renovate fails on `Validate RENOVATE_TOKEN` | the token is expired or lacks the `workflow` scope | recreate the token |
| the promotion PR never opens | `stable` does not exist | create the branch |
| the promotion PR will not merge | `stable` requires an approval | set required approvals to 0 |
| a Renovate PR waits forever | auto-merge is off | enable it in Settings |

## Runtime

The two most common first-boot surprises — no Flatpaks, and no `brew` — are in
the README's Troubleshooting section.

| Symptom | Cause | Fix |
|---|---|---|
| `ujust` shows no custom commands | `60-custom.just` was not written or imported | check that `10-overlay.sh` copied the recipes |
| `ssh` fails with `Permission denied (publickey)` and `ssh-add -l` says `Error connecting to agent` | `gcr-ssh-agent.socket` is not running, so `SSH_AUTH_SOCK` points at a socket with no listener. `gnome-session` used to start an agent and niri does not | the image enables it with `systemctl --global enable`; if the account disabled it, `systemctl --user enable --now gcr-ssh-agent.socket` |
| the greeter rejects a correct password (greetd logs `AUTH_ERR`) | `greeter.toml` has no `[keyboard]`, so the greeter's compositor is on libxkbcommon's `us` default | `systemctl status noctalia-greeter-setup.service`; compare the file's `[keyboard]` against `localectl status`. `Ctrl+Alt+F3` uses the console keymap, so logging in there proves it is the layout, not the account |
| the GRUB menu names the base image, not this one | ostree writes a BLS `title` only when it regenerates the bootloader config, and a rebase onto an image with the same kernel and kargs reuses the existing entries. The titles in `/boot/loader/entries/ostree-*.conf` then describe the deployments that were there when they were last written | cosmetic, and the next kernel bump corrects it. Trust `rpm-ostree status` over the menu. To force it, change the deployment set (`ostree admin pin --unpin N`, then `ostree admin undeploy N`) or rewrite the `title` line by hand |
| the hostname is the base image's name | nothing set a static hostname, so systemd falls back to `DEFAULT_HOSTNAME` in `os-release` | `00-image-info.sh` claims that key, along with `ID`, `ID_LIKE` and `CPE_NAME`. An installed machine keeps the transient name it already has until `hostnamectl set-hostname` |

## Capturing what you learned

When a fix here was non-obvious, put it in the skill that owns the area, in the
same pull request. That is the only home for durable learning.
