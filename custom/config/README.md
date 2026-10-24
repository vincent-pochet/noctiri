# custom/config

Per-user configuration, seeded into the `~/.config/` of every new user.

Files here are copied to `/etc/skel/.config/` at build time, so accounts created
after the build start with them. Existing users are left alone: rewriting a home
directory on every boot would discard their edits, so updating a user who
already exists is the `ujust install-config` command, never an automatic login
hook.

This is the last step in `build/10-overlay.sh`'s overlay order
(`common/shared`, `ublue-os/brew`, `custom/files`, then this one), so a file here
also wins over an inherited one — including the `/etc/skel/.config/` files that
Common ships. Overriding that way is intended.

`custom/files/` is the seam for system payloads outside `~/.config/`. The
`customize` skill decides which seam a given file belongs in.

`mimeapps.list` is the image's default-application table: Zen for the web
types, Thunderbird for mail and calendar. It is the first file the XDG
association chain reads, so it wins over the base image's defaults and over the
associations the Flatpak exports register. Both applications arrive on first
boot from `custom/flatpaks/`, and an entry naming a desktop file that is not
installed yet is skipped rather than an error.

`noctalia/10-theme-templates.toml` turns on Noctalia's `gtk3` and `gtk4`
templates, which is what carries the session's colour scheme into GTK
applications. Noctalia reads every `*.toml` in this directory and then lets
`~/.local/state/noctalia/settings.toml` — the file its Settings UI writes —
override the result, so this is a default rather than a setting the image holds
down. `build/60-niri-noctalia.sh` runs `noctalia config validate` over the
seeded directory, so an unknown key fails the build instead of every new
account.

`environment.d/10-example.conf` is the shipped example: inert as written, and
safe to replace.
