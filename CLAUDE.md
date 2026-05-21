# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A small framework for declaring and launching Incus containers. The repo
holds:

- **A generic launcher** (`bin/new`) that knows how to compose Incus
  profiles, apply per-profile host prep, launch a container, and run a
  per-container provisioning script.
- **Composable profiles** (`incus/profiles/`) — native Incus YAML, each
  granting one capability (GPU passthrough, bind-mount support, …).
- **Container manifests** (`manifests/<name>/`) — one directory per
  container type, holding a `container.sh` (declarative vars + hooks) and
  optionally a `setup.sh` (in-container provisioning).

`llm-agent` is the first manifest. More container types will be added as
sibling directories under `manifests/`.

## Concepts

Two layers, kept deliberately separate:

- **Profiles** are base features. They do not define what a container
  *does*; they grant it capabilities. A profile may carry host-level
  prerequisites in a sidecar `incus/profiles/<name>.host.sh`.
- **Containers** (manifests) pick an image, compose profiles, set
  capacity (`CONFIG`) and devices, and provision packages/config.

The repo intentionally uses **two formats only**:

- Incus profile YAML (forced by Incus).
- Bash (manifest + hooks + setup script).

No additional DSL is invented.

## Repo layout

```
containers/
├── README.md
├── CLAUDE.md
├── bin/
│   └── new                          # generic launcher
├── incus/
│   └── profiles/
│       ├── bind-mountable.yaml
│       ├── bind-mountable.host.sh   # optional host-prep sidecar
│       └── gpu-nvidia.yaml
└── manifests/
    └── llm-agent/
        ├── container.sh             # declarative manifest + hooks
        └── setup.sh                 # in-container provisioning
```

## `container.sh` — manifest spec

A bash file sourced by the launcher on the host.

### Required variables

| Var | Type | Purpose |
|---|---|---|
| `DESCRIPTION` | string | One-line description. Shown in `bin/new --list`. |
| `IMAGE` | string | Incus image ref, e.g. `images:archlinux`. |
| `PROFILES` | array | Profile names resolved against `incus/profiles/<name>.yaml`. Empty array allowed. |

### Optional variables

| Var | Default | Purpose |
|---|---|---|
| `CONFIG` | `()` | Flat `key=value` array. Splatted as `-c key=val` to `incus launch`. |
| `DEVICES` | `()` | Flat array. Each entry tails `incus config device add <NAME> <entry>`. Applied after launch. |
| `EPHEMERAL` | `0` | `1` to launch with `--ephemeral`. |
| `RESTART_AFTER_PROVISION` | `1` | `0` to skip the post-provision restart. |
| `SETUP_SCRIPT` | `setup.sh` | Path (relative to `CONTAINER_DIR`) of a script to push and run as `bash <path>` inside the container. Empty string skips provisioning. |

### Hooks

All hooks run on the **host** and are optional. In-container provisioning
is a separate script (`SETUP_SCRIPT`), not a hook.

| Hook | When | Extra scope |
|---|---|---|
| `hook_pre_launch` | After profile sync + host-prep, before `incus launch` | — |
| `hook_pre_setup` | After launch + devices + network ready, before pushing `SETUP_SCRIPT` | — |
| `hook_post_setup` | After `SETUP_SCRIPT` returns, before restart | — |
| `hook_post_launch` | After restart, with `$IP` resolved | `$IP` |

Hooks **fail-fast**: a non-zero exit aborts the launch.

### Variables and helpers exported to hooks

| Name | Available in | Source |
|---|---|---|
| `NAME` | all hooks | CLI arg — container name |
| `TYPE` | all hooks | CLI arg — manifest name (dir under `manifests/`) |
| `CONTAINER_DIR` | all hooks | Absolute path to `manifests/$TYPE/` |
| `REPO_ROOT` | all hooks | Absolute path to repo root |
| `IMAGE` | all hooks | from manifest |
| `PROFILES` | all hooks | from manifest |
| `IP` | `hook_post_launch` | incusbr0 IP, resolved after restart |
| `log()` | all hooks | Prints `<ISO-8601 timestamp> => <message>` to stderr. |

`incus` is assumed on `PATH`. The setup script receives no exported
variables — it is plain `bash <path>`, identical to invoking it manually.

## Profile host-prep sidecars

A profile may declare host-level prerequisites in
`incus/profiles/<name>.host.sh`. The launcher runs it (via `bash`)
whenever a manifest references the profile. Sidecars must be idempotent,
have `log()` available, and abort the launch on non-zero exit. Example:
`bind-mountable.yaml` uses `raw.idmap uid 1000 1000`, which requires
`root:1000:1` in `/etc/subuid` + `/etc/subgid` — added by
`bind-mountable.host.sh`.

## Launcher (`bin/new`)

### CLI

```
./bin/new <manifest> <name> [flags]
./bin/new --list
./bin/new -h | --help
```

- Positional args are required: `<manifest>` (dir under `manifests/`) and
  `<name>` (container name).
- Optional behavior is flag-driven (`--ephemeral`, `--no-restart`).

### Flow

1. Parse CLI args.
2. Source `manifests/$TYPE/container.sh`.
3. For each profile in `PROFILES`: sync the YAML into Incus, then run its
   `*.host.sh` sidecar if present.
4. Run `hook_pre_launch`.
5. `incus launch $IMAGE $NAME -p default {-p $p} {-c $kv} [--ephemeral]`.
6. For each entry in `DEVICES`: `incus config device add $NAME <entry>`.
7. If `SETUP_SCRIPT` non-empty: run `hook_pre_setup`, push + run, run
   `hook_post_setup`.
8. If `RESTART_AFTER_PROVISION=1`: `incus restart $NAME`.
9. Resolve `$IP`; run `hook_post_launch`.

## llm-agent specifics

Notes that future-you will need when editing
`manifests/llm-agent/setup.sh` or the manifest:

- **Display stack** is two systemd services owned by uid 1000:
  `agent-kasmvnc.service` (KasmVNC's combined X+VNC+web on `:8443`,
  passwordless via `-SecurityTypes None -disableBasicAuth`) and
  `agent-wm.service` (`openbox-session` with tint2 via openbox autostart).
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
- **Brave** runs with `--password-store=basic` via
  `~/.config/brave-flags.conf` to avoid kwallet noise (no KDE wallet in
  the container).

### Trust model

Shared uid 1000 + bind-mounted host dirs = **trusted-tool isolation**,
not hostile-code sandbox. A container escape lands as the host user.
Mitigates renderer-process compromise (renderer can't reach host
agents/PIDs) and accidental damage from a buggy agent (scoped to the
container FS). Does **not** defend against kernel/LXC escapes or unscoped
network egress on incusbr0. Harden by swapping `raw.idmap` for
`security.idmap.isolated: true`, dropping bind mounts, and using
`--ephemeral`.

## Known gotchas

- **subuid/subgid host prep is automated** via
  `bind-mountable.host.sh`. Without those lines, container start fails
  with `newuidmap: uid range [1000-1001) -> [1000-1001) not allowed`.
- **Arch base ships no fonts.** `setup.sh` installs `noto-fonts` and
  `ttf-dejavu`; without them GUI apps render as tofu.
- **KasmVNC RPM repack is glibc-sensitive.** Works today because Fedora 41
  and Arch both ship recent glibc. If upstream targets a newer-than-Arch
  glibc, switch to the AUR `kasmvncserver` source build.
- **Pacman post-install hooks log permission-denied** writing
  `/sys/.../uevent` inside unprivileged containers. Cosmetic; transactions
  complete. The `pac()` wrapper in `setup.sh` swallows this and explicit
  `pacman -Q` checks verify installs.
- **Brave produces dbus error noise** at startup (no session/system bus).
  Navigation works; quieting requires `dbus` + user session bus or
  `dbus-run-session`.
- **CachyOS v4 SIGILLs on pre-Zen 4 hosts.** Don't run setup on a host
  whose CPU lacks x86-64-v4.
- **KasmVNC runs without auth** (`-SecurityTypes None -disableBasicAuth`).
  Anything on incusbr0 reaching `:8443` gets a session. Add an
  `incus network acl`, or re-enable auth by dropping `-disableBasicAuth`
  and provisioning `~/.kasmpasswd` via `kasmvncpasswd`.

## Iteration loop

```sh
incus delete ca-test --force 2>/dev/null
./bin/new llm-agent ca-test
```

If `incus profile create` or `incus profile edit` hangs from a script
wrapper, run with an explicit `timeout` and retry — observed on this
host; retry usually succeeds.
