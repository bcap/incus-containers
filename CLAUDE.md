# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Incus profile + provisioning script that builds a container for running
**LLM coding agents and CLI tools**. Concrete requirements:

- NVIDIA GPU passthrough so local models can be GPU-accelerated.
- A minimal GUI (window manager + terminal + Brave) so agents can do
  browser automation while the user watches.
- VNC for that observation.
- Web services the agent runs are reachable from the host without explicit
  port mapping — the container has an incusbr0 IP and the host routes to it.

Two artifacts:

- `profile.yaml` — the Incus profile
- `setup.sh` — in-container provisioning (Arch base)

`README.md` is the public-facing usage doc.

## Architecture

**Display stack lives entirely inside the container** as two systemd
system services owned by uid 1000:

- `agent-kasmvnc.service` — KasmVNC's `Xvnc :99` (combined X server +
  VNC + websocket/web client), listening on `0.0.0.0:8443` (HTTPS web UI).
  Runs passwordless (`-SecurityTypes None -disableBasicAuth`).
- `agent-wm.service` — `openbox-session` with `tint2` panel launched via
  `~/.config/openbox/autostart`

The web client (https://<ip>:8443/) is the primary access path; raw RFB
clients (`vncviewer`) also work against the same port via KasmVNC's
protocol multiplexing. Reached via the container's `incusbr0` IP — no
`proxy` devices in the profile.

**KasmVNC install path:** no official Arch package and no upstream
generic tarball. We download the upstream Fedora 41 RPM (latest tagged
release) and extract with `bsdtar -xpf <rpm> -C /`. Runtime deps come
from pacman (`libjpeg-turbo`, `libwebp`, `gnutls`, `openssl`,
`libxfont2`, `pixman`, `perl`, `xkeyboard-config`, `xorg-xkbcomp`,
`xorg-xauth`, `libdrm`). Fragile to KasmVNC bumping glibc requirements
beyond Fedora 41 — revisit if install breaks.

**`raw.idmap uid 1000 1000` (+ gid)** maps the host user onto container uid
1000. This is for convenience: bind-mounting a host `~/code` round-trips
cleanly without ownership shifts. The required `root:1000:1` lines in
`/etc/subuid` and `/etc/subgid` on the host are documented in README.

**Bind mounts are NOT in the profile** — source path varies per user. README
documents `incus config device add ... shift=true` per container.

**NVIDIA via the `gpu` device** (`gputype: physical`) plus
`nvidia.driver.capabilities: all`. The container installs its own
`nvidia-utils` matching the host driver. `nvidia.runtime: true` would be
cleaner but currently fails at mount-hook time on this host
(Incus 7.0 + libnvidia-container 1.19).

**CachyOS repos** are enabled inside the container so `brave-bin` and
v4-optimized packages are available. Requires host CPU with x86-64-v4
support (Zen 4+ / Sapphire Rapids+).

**Brave runs with `--password-store=basic`** via `~/.config/brave-flags.conf`
to avoid kwallet noise at startup (no KDE wallet in the container).

## Trust model

Shared uid 1000 + bind-mounted host dirs = **trusted-tool isolation**, not
hostile-code sandbox. A container escape lands as the host user. Realistic
threats this still mitigates:

- Renderer-process compromise from a visited URL: the renderer can reach
  the in-container Xvfb (killable) and incusbr0 (firewallable). It cannot
  reach host KWin, host PIDs, the user's keyring/SSH/GPG agents, or any
  host process — namespace isolation is still intact.
- Accidental damage from a buggy agent: scoped to the container's FS
  except for whatever the user explicitly bind-mounts.

Things this does NOT defend against:

- A kernel-/LXC-level container escape — same uid as the host user.
- Network reachability: the container sits on incusbr0 with full LAN
  egress and no ACLs by default.

To harden for actively hostile agents, swap `raw.idmap` for
`security.idmap.isolated: true`, drop bind mounts, and consider
`--ephemeral` launches.

## Known gotchas

- **subuid/subgid host prep is mandatory.** Without `root:1000:1` lines,
  start fails with `newuidmap: uid range [1000-1001) -> [1000-1001) not allowed`.
- **Arch base ships no fonts.** Setup script installs `noto-fonts` and
  `ttf-dejavu`; without them GUI apps render as tofu.
- **KasmVNC RPM repack is glibc-sensitive.** Using the Fedora 41 RPM
  on Arch works today because both ship recent glibc. If KasmVNC upstream
  starts targeting a newer-than-Arch glibc, switch to the AUR
  `kasmvncserver` source build.
- **Pacman post-install hooks log permission-denied writing `/sys/.../uevent`**
  inside unprivileged containers. Cosmetic; transactions complete.
- **Brave produces dbus error noise** at startup (no session/system bus).
  Navigation works; quieting requires `dbus` + a user session bus, or
  `dbus-run-session`.
- **CachyOS v4 SIGILLs on pre-Zen 4 hosts.** Don't run setup on a host
  whose CPU lacks x86-64-v4.
- **KasmVNC runs without auth** (`-SecurityTypes None -disableBasicAuth`).
  Anything on incusbr0 reaching :8443 gets a session. Add an
  `incus network acl` if running multiple containers on the same bridge,
  or re-enable auth by dropping `-disableBasicAuth` and provisioning
  `~/.kasmpasswd` via `kasmvncpasswd`.

## Iteration loop

```sh
incus delete ca-test --force 2>/dev/null
incus profile edit llm-agent < profile.yaml
incus launch images:archlinux ca-test -p default -p llm-agent
incus file push setup.sh ca-test/root/setup.sh --mode 0755
incus exec ca-test -- bash /root/setup.sh
incus restart ca-test
```

Smoke tests are in `README.md`.

If `incus profile create` or `incus profile edit` hangs from a script
wrapper, run with an explicit `timeout` and retry — observed on this host;
retry usually succeeds.

# Ideas

## Higher-fidelity GUI access (replace Xvfb + x11vnc)

Current stack (Xvfb + x11vnc) is the floor for remote GUI quality. Worth
exploring better options. GPU passthrough is **not** assumed — must work CPU-only too.

Tiers considered:
- **VNC family** (x11vnc/TigerVNC/TurboVNC): RFB, ~30fps cap, no audio, sluggish on motion. Current.
- **KasmVNC**: VNC fork w/ H.264+WebP, web client, audio, clipboard, multi-monitor. Big jump, CPU-friendly. Lowest-friction upgrade.
- **xrdp / NICE DCV**: middling; DCV nicer but closed source and value drops without GPU.
- **Sunshine + Moonlight**: NVENC when GPU available, libx264/SVT fallback on CPU. Same low-latency protocol + audio + HID either way. Highest ceiling.
- **Waypipe / X11 forward**: wrong paradigm for "watch agent use browser."

Leaning: **Sunshine with encoder auto-detect** for ceiling, or **KasmVNC** if predictable CPU cost matters more than peak quality. Sunshine assumes single interactive session per container; KasmVNC friendlier for multi-user/headless-CI shapes.
