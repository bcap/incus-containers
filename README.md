# containers

A personal collection of Incus container definitions and a small launcher
to build them.

The repo is two things:

- A generic launcher (`bin/new`) that composes Incus profiles, runs any
  per-profile host prep, launches a container, and provisions it.
- A growing set of **container manifests** (`manifests/<name>/`), one per
  container type. Currently:
  - **dev** — GUI development container. NVIDIA passthrough, KasmVNC
    web client, Brave, openbox.

See `CLAUDE.md` for the full manifest spec and internals.

## Requirements

- Linux host with [Incus](https://linuxcontainers.org/incus/) installed.
- For `dev` specifically: NVIDIA GPU + driver on the host, and a
  modern CPU (Zen 4 / Sapphire Rapids or newer) for CachyOS v4 packages.

## Launch a container

```sh
./bin/new <manifest> <name>
```

Examples:

```sh
./bin/new dev my-dev               # GUI development container
./bin/new --list                   # show available manifests
./bin/new --help
```

The launcher handles host prep (e.g. subuid/subgid for bind mounts),
syncs Incus profiles from `incus/profiles/`, launches the container, and
runs the manifest's `setup.sh` inside it. Takes a couple of minutes the
first time.

When it finishes you'll see (for `dev`):

```
… => Container 'my-dev' ready.
…    IP:    10.x.y.z
…    Web:   https://10.x.y.z:8443/vnc.html
…    VNC:   vncviewer 10.x.y.z:8443
…    Shell: incus exec my-dev -- sudo -iu user
```

## Use a dev container

**Watch the desktop** — open the web client in any browser (self-signed
cert; accept the warning):

```
https://10.x.y.z:8443/vnc.html
```

Or use a native VNC client against the same port:

```sh
vncviewer 10.x.y.z:8443
```

**Drop into a shell:**

```sh
incus exec my-dev -- sudo -iu user
```

**Share a code directory with the host:**

```sh
incus config device add my-dev code disk \
  source=/home/$USER/code \
  path=/home/user/code \
  shift=true
```

Files appear owned by your user on both sides.

**Reach a web service running inside** (e.g. a dev server on `:3000`):

```sh
curl http://10.x.y.z:3000/
```

## Manage containers

```sh
incus list                          # see what's running
incus stop my-dev                 # stop
incus start my-dev                # start again
incus delete my-dev --force       # destroy
```

## Add a new container type

1. Create `manifests/<name>/container.sh` (bash, sourced on the host by
   `bin/new`). Set at least `DESCRIPTION`, `IMAGE`, `PROFILES`.
2. Optionally add `manifests/<name>/setup.sh` for in-container
   provisioning (pushed and run as `bash <path>` inside the container).
3. If you need a new capability, add a profile under `incus/profiles/`
   (and an optional `<name>.host.sh` sidecar for host prep).

### `container.sh` spec

**Required variables**

| Var | Type | Purpose |
|---|---|---|
| `DESCRIPTION` | string | One-line description, shown in `bin/new --list`. |
| `IMAGE` | string | Incus image ref, e.g. `images:archlinux`. |
| `PROFILES` | array | Profile names resolved against `incus/profiles/<name>.yaml`. Empty array allowed. |

**Optional variables**

| Var | Default | Purpose |
|---|---|---|
| `CONFIG` | `()` | Flat `key=value` array. Splatted as `-c key=val` to `incus launch`. |
| `DEVICES` | `()` | Flat array. Each entry tails `incus config device add <NAME> <entry>`. Applied after launch. |
| `EPHEMERAL` | `0` | `1` to launch with `--ephemeral`. |
| `RESTART_AFTER_PROVISION` | `1` | `0` to skip the post-provision restart. |
| `SETUP_SCRIPT` | `setup.sh` | Path (relative to `CONTAINER_DIR`) of a script pushed and run inside the container. Empty string skips provisioning. |

**Hooks** (all run on the host, all optional, fail-fast on non-zero exit)

| Hook | When | Extra scope |
|---|---|---|
| `hook_pre_launch` | After profile sync + host-prep, before `incus launch` | — |
| `hook_pre_setup` | After launch + devices + network ready, before pushing `SETUP_SCRIPT` | — |
| `hook_post_setup` | After `SETUP_SCRIPT` returns, before restart | — |
| `hook_post_launch` | After restart, with `$IP` resolved | `$IP` |

**Variables and helpers exported to hooks**

| Name | Available in | Source |
|---|---|---|
| `NAME` | all hooks | CLI arg — container name |
| `TYPE` | all hooks | CLI arg — manifest name |
| `CONTAINER_DIR` | all hooks | Absolute path to `manifests/$TYPE/` |
| `REPO_ROOT` | all hooks | Absolute path to repo root |
| `IMAGE` | all hooks | from manifest |
| `PROFILES` | all hooks | from manifest |
| `IP` | `hook_post_launch` | incusbr0 IP, resolved after restart |
| `log()` | all hooks | Prints `<ISO-8601 timestamp> => <message>` to stderr |

### Profile host-prep sidecars

A profile may declare host-level prerequisites in
`incus/profiles/<name>.host.sh`. The launcher runs it (via `bash`)
whenever a manifest references the profile. Sidecars must be idempotent,
have `log()` available, and abort the launch on non-zero exit. Example:
`bind-mountable.yaml` needs `root:1000:1` in `/etc/subuid`/`subgid` —
added by `bind-mountable.host.sh`.

See `CLAUDE.md` for additional internals and the `dev`-specific notes.
