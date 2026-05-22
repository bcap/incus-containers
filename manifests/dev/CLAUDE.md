# dev container specifics

Notes that future-you will need when editing `setup.sh` or `container.sh`
in this directory.

- **Display stack** is two systemd services owned by uid 1000:
  `kasmvnc.service` (KasmVNC's combined X+VNC+web on `:8443`,
  passwordless via `-SecurityTypes None -disableBasicAuth`) and
  `wm.service` (`openbox-session` with tint2 via openbox autostart).
- **KasmVNC install path:** no Arch package, no generic tarball. The
  setup script downloads the upstream Fedora 41 RPM and extracts with
  `bsdtar -xpf <rpm> -C /`. Runtime deps come from pacman. Fragile to
  KasmVNC bumping glibc requirements beyond Fedora 41 — revisit if
  install breaks.
- **NVIDIA** via the `gpu-nvidia` profile (`gputype: physical` +
  `nvidia.driver.capabilities: all`). The container installs its own
  `nvidia-utils` matching the host driver. `nvidia.runtime: true` would
  be cleaner but currently fails at mount-hook time on this host
  (Incus 7.0 + libnvidia-container 1.19).
- **CachyOS repos** are enabled inside the container so `brave-bin` and
  v4-optimized packages are available. Requires a host CPU with
  x86-64-v4 support (Zen 4+ / Sapphire Rapids+).
- **KasmVNC IME mode** is enabled in `kasmvnc.yaml` (`keyboard.ime_mode:
  enabled`). Required when the host uses a dead-key layout (e.g.
  `us(alt-intl)` for Portuguese accents): without it the browser drops
  `Dead` keysyms and `~`, `^`, `` ` `` never reach the server. IME mode
  forwards composed text instead of raw keysyms.
- **Brave** runs with `--password-store=basic` via
  `~/.config/brave-flags.conf` to avoid kwallet noise (no KDE wallet in
  the container).

## Trust model

Shared uid 1000 + bind-mounted host dirs = **trusted-tool isolation**,
not hostile-code sandbox. A container escape lands as the host user.
Mitigates renderer-process compromise (renderer can't reach host
agents/PIDs) and accidental damage from a buggy agent (scoped to the
container FS). Does **not** defend against kernel/LXC escapes or unscoped
network egress on incusbr0. Harden by swapping `raw.idmap` for
`security.idmap.isolated: true`, dropping bind mounts, and using
`--ephemeral`.
