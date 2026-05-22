# dev container specifics

Notes that future-you will need when editing `setup.sh` or `container.sh`
in this directory.

- **Display stack** is two systemd services owned by uid 1000:
  `kasmvnc.service` (KasmVNC's combined X+VNC+web on `:8443`,
  passwordless via `-SecurityTypes None -disableBasicAuth`) and
  `wm.service` (`openbox-session` with tint2 via openbox autostart).
- **Resolution** is dynamic: initial geometry `SCREEN_W`x`SCREEN_H`
  (default 3840x2160) acts as the cap; KasmVNC's "Remote Resizing"
  (web UI > Settings > Display) lets the client downscale to fit the
  browser viewport via RandR. `max_resolution` in `kasmvnc.yaml`
  enforces the upper bound;
  `allow_client_to_override_kasm_server_settings: true` lets the
  client request resizes at runtime.
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
- **KasmVNC IME mode** is a *client-side only* toggle (`enable_ime` in
  the browser's localStorage, default `false`). There is no server YAML
  key for it — the upstream KasmVNC config has no `keyboard.ime_mode`.
  Force it on for first connect via the URL query parameter
  `?enable_ime=true` (read by `initSetting` via `WebUtil.getConfigVar`,
  then persisted to localStorage). `hook_post_launch` in `container.sh`
  prints the URL with that param appended. Required when the host uses
  a dead-key layout (e.g. `us(alt-intl)` for Portuguese accents):
  without it the browser drops `Dead` keysyms and `~`, `^`, `` ` ``
  never reach the server.
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
