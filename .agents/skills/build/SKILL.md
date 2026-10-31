---
name: build
description: >-
  The Containerfile, Justfile, build phases, image pinning, and the example
  scripts. Use when changing how the image is assembled or activating an
  example.
---

# Build

## The Containerfile

It is the source of truth for image assembly, and it is written to be read. Its
structure, in order:

1. **Identity** — `ARG IMAGE_NAME`, `IMAGE_VENDOR`, `UBLUE_IMAGE_TAG`, and the
   `# Name:` comment. The name actually published is the repository name; these
   are the local fallback and the image metadata.
2. **Context stage** — `COPY build /build`, `COPY custom /custom`, then the two
   OCI images into `/oci/common` and `/oci/brew`.
3. **Base** — the `FROM` line. The only place the base is chosen; the Fedora
   major, the image name, and the digest all follow from it.
4. **Phases** — one `RUN` block per script, in the order they are named.
   [build/README.md](../../../build/README.md) lists them.
5. **Metadata** — the `LABEL` block, fed by ARGs declared late so a new version
   or commit only invalidates the label layer.

Order matters for cache: volatile values go after the expensive layers.

## The Justfile

```bash
just build            # build the image
just build-qcow2      # build a QCOW2 disk image
just build-iso        # build an installer ISO
just run-vm-qcow2     # boot the image in a VM
just test-unit        # run the suite
just lint             # shellcheck every tracked script
just check            # verify Justfile syntax
```

`just --list` has the rest. `IMAGE_NAME` defaults to the value in the Justfile
and is overridable by the `IMAGE_NAME` environment variable; CI sets that from
the repository name.

## Pinning

Every OCI reference is pinned by digest and updated by Renovate: the base image,
`projectbluefin/common`, `ublue-os/brew`, `bootc-image-builder`, and the GitHub
Actions. Do not hand-edit a digest; let Renovate propose it.

The base image's `FROM` line is the only place the base is chosen, so the Fedora
major cannot desync the way a hand-maintained `FEDORA_MAJOR_VERSION` ARG could.
Two readers derive it from that base: `just build` parses the tag for the version
string, and `00-image-info.sh` reads the base's `os-release` for the image
metadata.

`BASE_IMAGE_NAME` has no default in the Containerfile on purpose: a stale default
like `silverblue` would silently mislabel a CentOS or Hummingbird fork. `just
build` fills it from the `FROM` line and `00-image-info.sh` hard-fails on an empty
value, so build through `just`; a bare `podman build .` is unsupported.

## Image identity

`00-image-info.sh` owns `/usr/lib/os-release`. It claims every key that names the
operating system — `NAME`, `PRETTY_NAME`, `ID`, `DEFAULT_HOSTNAME`, `CPE_NAME`,
`VARIANT_ID`, the URLs — because a key left at the base image's value is a key
through which the installed system keeps introducing itself as its base. `ID` and
`DEFAULT_HOSTNAME` are the two that reach past cosmetics: systemd falls back to
`DEFAULT_HOSTNAME` for an unconfigured hostname, and bootc installers derive the
ostree stateroot name from `ID`. Taking `ID` is why `ID_LIKE` is rebuilt from the
base's own `ID` and `ID_LIKE` — otherwise the base drops out of the derivation
chain that scripts fall back to.

Keys that describe the *base* stay as they are: `VERSION_ID`, `VERSION_CODENAME`,
`SUPPORT_END`. `60-niri-noctalia.sh` then overwrites `VARIANT`/`VARIANT_ID` with
the desktop, which is the one place two phases write the same key.

## Examples

`build/*.sh.example` are inactive until you activate them: rename the file off
`.example` and add a `RUN` block after the package phase.
[build/README.md](../../../build/README.md) has the block to copy.
