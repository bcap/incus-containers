# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A small framework for declaring and launching Incus containers. The repo
holds:

- **A generic launcher** (`bin/new`) that knows how to compose Incus
  profiles, apply per-profile host prep, launch a container, and run a
  list of per-container provisioning scripts.
- **A generic cloner** (`bin/clone`) that clones any Incus container
  (not just ones built from this repo's manifests), duplicating each
  referenced custom storage volume so source and clone share no
  storage.
- **Composable profiles** (`incus/profiles/`) — native Incus YAML, each
  granting one capability (GPU passthrough, bind-mount support, …).
- **Container manifests** (`manifests/<name>/`) — one directory per
  container type, holding a `container.sh` (declarative vars + hooks) and
  one or more setup scripts (in-container provisioning). Manifests can
  reuse setup scripts from sibling manifests via relative paths
  (e.g. `../dev/base.sh`) — `dev-gui` is built on `dev`'s base+user
  scripts plus its own `gui.sh`.

Current manifests: `dev` (headless base + user), `dev-gui` (`dev` +
LXQt/KasmVNC GUI). More will be added as sibling directories under
`manifests/`.

## Concepts

Two layers, kept deliberately separate:

- **Profiles** are base features. They do not define what a container
  *does*; they grant it capabilities. A profile may carry host-level
  prerequisites in a sidecar `incus/profiles/<name>.host.sh`.
- **Containers** (manifests) pick an image, compose profiles, set
  capacity (`CONFIG`) and devices, and provision packages/config.

The repo intentionally uses **two formats only**:

- Incus profile YAML (forced by Incus).
- Bash (manifest + hooks + setup scripts).

No additional DSL is invented.

## Repo layout

```
containers/
├── README.md
├── CLAUDE.md
├── bin/
│   ├── new                          # generic launcher
│   └── clone                        # generic container+volumes cloner
├── incus/
│   └── profiles/
│       ├── bind-mountable.yaml
│       ├── bind-mountable.host.sh   # optional host-prep sidecar
│       └── gpu-nvidia.yaml
└── manifests/
    ├── dev/
    │   ├── container.sh             # declarative manifest + hooks
    │   ├── base.sh                  # CachyOS repos + base toolchain
    │   └── user.sh                  # 'user' uid 1000 + zsh
    └── dev-gui/
        ├── container.sh             # reuses ../dev/{base,user}.sh
        └── gui.sh                   # LXQt + KasmVNC + Brave
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
| `SETUP_SCRIPTS` | `(setup.sh)` | Bash array of script paths. Each is pushed to `/root/<basename>` and run as `bash /root/<basename>` inside the container, in order. Relative paths resolve against `CONTAINER_DIR` — `../<other-manifest>/foo.sh` lets one manifest reuse another's scripts. Basenames must be unique across the array. Empty array skips provisioning. |

### Hooks

All hooks run on the **host** and are optional. In-container provisioning
is done by the `SETUP_SCRIPTS` array, not by hooks.

| Hook | When | Extra scope |
|---|---|---|
| `hook_pre_launch` | After profile sync + host-prep, before `incus launch` | — |
| `hook_pre_setup` | After launch + devices + network ready, before pushing the *first* setup script | — |
| `hook_post_setup` | After the *last* setup script returns, before restart | — |
| `hook_post_launch` | After restart, with `$IP` resolved | `$IP` |

`hook_pre_setup` / `hook_post_setup` fire **once** around the whole
`SETUP_SCRIPTS` sequence — not per-script.

Hooks **fail-fast**: a non-zero exit aborts the launch.

### Variables and helpers exported to hooks

| Name | Available in | Source |
|---|---|---|
| `NAME` | all hooks | CLI arg — container name |
| `MANIFEST` | all hooks | CLI arg — manifest name (dir under `manifests/`) |
| `CONTAINER_DIR` | all hooks | Absolute path to `manifests/$MANIFEST/` |
| `REPO_ROOT` | all hooks | Absolute path to repo root |
| `IMAGE` | all hooks | from manifest |
| `PROFILES` | all hooks | from manifest |
| `IP` | `hook_post_launch` | incusbr0 IP, resolved after restart |
| `log()` | all hooks | Prints `<ISO-8601 timestamp> => <message>` to stderr. |

`incus` is assumed on `PATH`. Setup scripts receive no exported
variables — each is plain `bash /root/<basename>`, identical to invoking
it manually. Because scripts are executed (not sourced) and run
independently, each one needs its own helpers (`log`, `pac_install`,
root check, etc.); state from one does not survive to the next, beyond
what the script writes into the container's filesystem.

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
- Optional behavior is flag-driven.

| Flag | Purpose |
|---|---|
| `--ephemeral` | Launch with `--ephemeral` (overrides manifest). |
| `--no-restart` | Skip the post-provision restart. |
| `--split=<spec>` | Split paths onto custom storage volumes. `<spec>` = `<path>[:<vol>][,<path>[:<vol>]...]`. Path must be absolute and not `/`. Volume defaults to `<NAME>-<sanitized-path>` (slashes → `-`). Last `--split` wins. Mutually exclusive with `--split-home`. |
| `--split-home[=<vol>]` | Sugar for `--split=/home[:<vol>]`. |
| `--reuse[=<paths>]` | Allow reusing pre-existing volumes. No value → reuse all split paths. With value (comma-separated paths) → only listed paths may reuse; any other split whose volume already exists errors. Requires `--split` or `--split-home`. |
| `--pool=<pool>` | Storage pool for created/probed volumes (default `default`). |

### Split-volume model

Volumes are created (`incus storage volume create <pool> <vol>
security.shifted=true`) before launch and attached as disk devices
*after* launch but *before* setup scripts run. Hot-mount, no restart.
`security.shifted=true` carries the uid 1000 idmap onto the custom
volume so files inside appear owned by `user` — no `raw.idmap` profile
needed for the split path itself.

On reuse, the existing volume's contents become visible at the split
path before setup scripts run. Setup scripts must be **idempotent on
reused storage**: guard work that writes into the split path with
content markers, not mere file-existence checks. Example: `dev/user.sh`
gates the custom `.zshrc` write on `grep '^function _prompt'` rather
than `[[ ! -f .zshrc ]]`, because oh-my-zsh's installer also creates a
template `.zshrc`. New setup scripts that touch split paths should
follow the same pattern.

Volume name default: `<NAME>-<sanitized-path>` (leading `/` stripped,
inner `/` → `-`). So `--split=/home` → `<NAME>-home`,
`--split=/var/lib/docker` → `<NAME>-var-lib-docker`. Device names follow
the same scheme with a `split-` prefix.

### Flow

1. Parse CLI args.
2. Source `manifests/$MANIFEST/container.sh`.
3. For each profile in `PROFILES`: sync the YAML into Incus, then run its
   `*.host.sh` sidecar if present.
4. Build split-volume specs from `--split` / `--split-home`. For each
   spec: probe `incus storage volume show $POOL $VOL`. Error out on
   existing volume unless `--reuse` permits; otherwise
   `incus storage volume create $POOL $VOL security.shifted=true`.
5. Run `hook_pre_launch`.
6. Resolve + validate every `SETUP_SCRIPTS` path (relative → joined with
   `CONTAINER_DIR`, then `realpath -m`). Fails fast on missing files or
   basename collisions, before launching anything.
7. `incus launch $IMAGE $NAME -p default {-p $p} {-c $kv} [--ephemeral]`.
8. For each split spec: `incus config device add $NAME split-<sanitized>
   disk pool=$POOL source=$VOL path=$PATH` (hot-mount).
9. For each entry in `DEVICES`: `incus config device add $NAME <entry>`.
10. Push `/etc/incus-vars` into the container (see *Container-side vars*
    below).
11. If `SETUP_SCRIPTS` non-empty: run `hook_pre_setup`, then for each
    resolved path push to `/root/<basename>` and `bash` it; finally run
    `hook_post_setup`.
12. If `RESTART_AFTER_PROVISION=1`: `incus restart $NAME`.
13. Resolve `$IP`; run `hook_post_launch`.

## Cloner (`bin/clone`)

Generic — works on any Incus container, not just manifests from this
repo. `incus copy` alone clones the instance root but leaves the new
instance's custom-volume disk devices pointing at the **source's**
volumes (shared, not duplicated). `bin/clone` copies each referenced
volume to a new name and rewrites the clone's devices to point at the
copies.

### CLI

```
./bin/clone <src> <dst> [flags]
./bin/clone -h | --help
```

| Flag | Purpose |
|---|---|
| `--stop` | Stop `<src>` before copying (filesystem-consistent clone). Restart after if it was running. Without this, `incus copy` does a stateless copy of a live container. |
| `--start` | Start `<dst>` after cloning. Default: leave stopped, matching `incus copy`. |
| `--no-snapshots` | Skip snapshots on both instance and volume copies (passes `--instance-only` / `--volume-only`). |
| `--vol=<srcvol>=<dstvol>[,...]` | Override new volume names per-volume. |
| `--pool=<pool>` | Force all new volumes onto `<pool>`. Default: each new volume stays on its source volume's pool. |

### What gets cloned

Only **instance-local** disk devices (`incus config device list <src>`)
with both `pool` and `source` set are treated as custom-volume mounts and
duplicated. That excludes:

- the root disk (`pool` set, `source` empty);
- bind mounts (`source` is a host path, no `pool`);
- profile-inherited disks (not in the instance-local device list —
  these are shared across instances by design).

### Volume rename rules

Default: if the source volume name contains the source container name,
substitute (bash `${vol//$SRC/$DST}`); else prepend `${DST}-`. So with
`--split-home` volumes (`<NAME>-home`), cloning `dev` → `dev-clone`
produces `dev-clone-home`. Override per-volume with `--vol`.

If a computed destination volume already exists, the script errors out
before doing anything — pass `--vol` to pick a different name.

### Implementation notes

- Uses `incus config device set <dev> source=<newvol>` (not
  remove+re-add) so other device properties (`readonly`, `propagation`,
  `shift`, `recursive`, …) survive untouched.
- Dedupes shared volumes: if one source volume is mounted at multiple
  paths, it's copied once and every dst device points at the same new
  volume.
- `/etc/incus-vars` inside the clone still reflects the **source's**
  provisioning context (`NAME`, `MANIFEST`, `SPLITS`, `PROVISIONED_AT`,
  `REPO_REV`). The cloner doesn't rewrite it — anything that needs a
  fresh `NAME` should be regenerated by the consumer (e.g. for
  `dev-gui`'s wallpaper, restart the container so the
  `gen-wallpaper.service` oneshot re-runs against the new hostname, or
  edit `/etc/incus-vars` manually).

## Container-side vars (`/etc/incus-vars`)

The launcher writes `/etc/incus-vars` inside every container before
running setup scripts, so both setup scripts and runtime tools can pick
up host-known facts that aren't trivially recoverable from inside.
Shell-sourceable (`. /etc/incus-vars`); values are `%q`-quoted so
strings with spaces or special chars round-trip safely.

| Key | Source |
|---|---|
| `NAME` | container name (CLI arg) |
| `MANIFEST` | manifest dir name (CLI arg) |
| `DESCRIPTION` | manifest `DESCRIPTION` |
| `IMAGE` | manifest `IMAGE` |
| `PROFILES` | manifest `PROFILES` joined with spaces |
| `POOL` | `--pool` value (default `default`) |
| `SPLITS` | Space-separated `<path>:<pool>:<volume>` tokens for each split path. Empty when no `--split{,-home}` was given. |
| `PROVISIONED_AT` | `date -Iseconds` at write time |
| `REPO_REV` | `git rev-parse HEAD` of this repo; empty if not a git checkout |

`IP` is intentionally **not** included — it's queryable inside
(`ip -4 -o addr show scope global`) and would be wrong if written
pre-restart (DHCP may reassign on restart). `REPO_REV` reflects the
checkout state at provision time; it does not update on container
restart.

Used today by `manifests/dev-gui/gui.sh`'s `/usr/local/bin/gen-wallpaper`
to render the description on the desktop background.

## Per-manifest notes

- `dev`: see [manifests/dev/CLAUDE.md](manifests/dev/CLAUDE.md).
- `dev-gui`: see [manifests/dev-gui/CLAUDE.md](manifests/dev-gui/CLAUDE.md).

## Networking

- `incusbr0` uses `10.10.0.1/24` (gateway). Convention for future
  bridges: keep `10.10.X.1/24`, varying the third octet per network.
- Containers are reachable from the host as `<name>.incus` via incus's
  built-in dnsmasq. DNS routing is bound to the `incusbr0` *link* (not
  global) by a oneshot systemd unit at
  `/etc/systemd/system/incus-resolved.service`:

  ```
  [Unit]
  Description=Bind *.incus DNS routing to incusbr0
  After=incus.service
  Requires=incus.service

  [Service]
  Type=oneshot
  RemainAfterExit=yes
  ExecStart=/usr/bin/resolvectl dns incusbr0 10.10.0.1
  ExecStart=/usr/bin/resolvectl domain incusbr0 ~incus

  [Install]
  WantedBy=multi-user.target
  ```

  Per-link is critical: a global `/etc/systemd/resolved.conf.d/*.conf`
  drop-in with the same `DNS=` + `Domains=~incus` lines hijacks *all*
  DNS when no other global server is configured (NetworkManager pushes
  DNS per-link, not global). Symptom of that mistake: SRV queries time
  out → `gpg --recv-keys` fails with "Server indicated a failure" (e.g.
  CachyOS repo bootstrap breaks). DHCP-assigned IPs are MAC-hashed and
  stable per container, but prefer `<name>.incus` over raw IPs.

## Known gotchas

- **subuid/subgid host prep is automated** via
  `bind-mountable.host.sh`. Without those lines, container start fails
  with `newuidmap: uid range [1000-1001) -> [1000-1001) not allowed`.
- **Arch base ships no fonts.** `dev-gui/gui.sh` installs `noto-fonts`
  and `ttf-dejavu`; without them GUI apps render as tofu.
- **KasmVNC RPM repack is glibc-sensitive.** Works today because Fedora 41
  and Arch both ship recent glibc. If upstream targets a newer-than-Arch
  glibc, switch to the AUR `kasmvncserver` source build.
- **Pacman post-install hooks log permission-denied** writing
  `/sys/.../uevent` inside unprivileged containers. Cosmetic; transactions
  complete. The `pac_install()` wrapper in every setup script swallows
  this and verifies with `pacman -Q`.
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
./bin/new dev ca-test
```

If `incus profile create` or `incus profile edit` hangs from a script
wrapper, run with an explicit `timeout` and retry — observed on this
host; retry usually succeeds.
