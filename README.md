# containers

A personal collection of Incus container definitions and a small launcher
to build them.

The repo is two things:

- A generic launcher (`bin/new`) that composes Incus profiles, runs any
  per-profile host prep, launches a container, and provisions it with a
  list of setup scripts (which may be shared across manifests).
- A growing set of **container manifests** (`manifests/<name>/`), one per
  container type. Currently:
  - **dev** — headless dev container. Arch + CachyOS repos, base
    toolchain, `user` uid 1000 with zsh, NVIDIA passthrough.
  - **dev-gui** — `dev` plus a KasmVNC web desktop (LXQt + Brave +
    alacritty + tmux). Reuses `dev`'s `base.sh` and `user.sh` via
    relative paths in `SETUP_SCRIPTS`.

See `CLAUDE.md` for the full manifest spec and internals.

## Requirements

- Linux host with [Incus](https://linuxcontainers.org/incus/) installed.
- For `dev` / `dev-gui`: NVIDIA GPU + driver on the host, and a modern
  CPU (Zen 4 / Sapphire Rapids or newer) for CachyOS v4 packages.

## Launch a container

```sh
./bin/new <manifest> <name>
```

Examples:

```sh
./bin/new dev my-dev               # headless dev container
./bin/new dev-gui my-desktop       # same, plus KasmVNC desktop
./bin/new --list                   # show available manifests
./bin/new --help
```

### Persistent /home across rebuilds

By default a container's `/` and `/home` live on the same root volume —
`incus delete` wipes everything. To survive rebuilds, split `/home` onto
its own storage volume:

```sh
./bin/new dev my-dev --split-home                  # creates volume my-dev-home
./bin/new dev my-dev --split-home=shared           # use named volume "shared"
./bin/new dev my-dev --split=/home,/var/lib/docker # multiple split points
```

After deleting the container the volume persists; rebuild with `--reuse`
to mount it again:

```sh
incus delete my-dev --force
./bin/new dev my-dev --split-home --reuse          # /home/user, dotfiles, etc. survive
```

`--reuse` with no value reuses *any* split volume that already exists;
pass paths (`--reuse=/home`) to allow only specific ones. Any other
split whose volume already exists causes an error — guards against
silently shadowing data.

`--pool=<pool>` picks the storage pool for created/probed volumes
(default: `default`).

The launcher handles host prep (e.g. subuid/subgid for bind mounts),
syncs Incus profiles from `incus/profiles/`, launches the container, and
runs each script in the manifest's `SETUP_SCRIPTS` array inside it (each
gets pushed to `/root/<basename>` and executed as `bash`, in order).
Takes a couple of minutes the first time.

When it finishes you'll see (for `dev-gui`):

```
… => Container 'my-desktop' ready.
…    IP:     10.x.y.z
…    DNS:    my-desktop.incus
…    WebVNC: http://my-desktop.incus  (redirects to https://my-desktop.incus:8443/vnc.html?enable_ime=true)
…    Shell:  incus exec my-desktop -- sudo -iu user
```

`dev` (headless) prints just the IP + shell hint — no KasmVNC.

## Use a dev container

**Watch the desktop** (`dev-gui` only) — open the web client in any
browser (self-signed cert; accept the warning):

```
http://<name>.incus            # :80 redirects to the URL below
https://<name>.incus:8443/vnc.html?enable_ime=true
```

Or use a native VNC client against the same port:

```sh
vncviewer <name>.incus:8443
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

## Networking

`incusbr0` is `10.10.0.1/24`. Containers are reachable from the host as
`<name>.incus` (e.g. `ssh user@dev.incus`, `https://dev.incus:8443`),
served by incus's built-in dnsmasq. Wire the host resolver once by
binding `*.incus` to the `incusbr0` link (per-link, not global — see
note below):

```sh
sudo tee /etc/systemd/system/incus-resolved.service >/dev/null <<'EOF'
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
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now incus-resolved.service
```

Do *not* use a global `/etc/systemd/resolved.conf.d/*.conf` drop-in with
`DNS=10.10.0.1`. On NetworkManager systems that push DNS per-link, the
drop-in becomes the only global DNS server and the `~incus` routing
domain doesn't restrict it. Non-`*.incus` queries (notably SRV) then
get routed to incus's dnsmasq and time out — which manifests as
`gpg --recv-keys` failing with "Server indicated a failure".

## Manage containers

```sh
incus list                          # see what's running
incus stop my-dev                 # stop
incus start my-dev                # start again
incus delete my-dev --force       # destroy
```

## Clone a container

`bin/clone` is a generic clone for any Incus container — not specific to
this repo's manifests. `incus copy` alone leaves the clone's custom-volume
disk devices pointing at the **source's** volumes (they get shared, not
duplicated); `bin/clone` copies each referenced volume to a new name and
rewrites the clone's devices to point at the copies, so source and clone
share no storage.

```sh
./bin/clone my-dev my-dev-copy                    # clone, leave stopped
./bin/clone my-dev my-dev-copy --stop --start     # consistent copy, start clone
./bin/clone my-dev my-dev-copy --no-snapshots     # skip snapshots
./bin/clone my-dev my-dev-copy --vol=my-dev-home=mydev-home-bak
./bin/clone my-dev my-dev-copy --pool=fast        # send new volumes to a pool
```

New volume names default to `${srcvol/$SRC/$DST}` (or `${DST}-${srcvol}` if
the source vol name doesn't contain the source container name). Profile-
inherited devices are left as-is — their volumes are shared by design.
Only **instance-local** disk devices with both `pool` and `source` set are
considered custom volumes; bind mounts (host-path `source`, no `pool`) and
the root disk are not duplicated.

## Add a new container type

1. Create `manifests/<name>/container.sh` (bash, sourced on the host by
   `bin/new`). Set at least `DESCRIPTION`, `IMAGE`, `PROFILES`.
2. Drop one or more setup scripts into `manifests/<name>/` and list them
   in `SETUP_SCRIPTS=(...)`. Each is pushed to `/root/<basename>` and
   run as `bash` inside the container, in order. Relative paths resolve
   against the manifest's directory, so `../<other-manifest>/foo.sh`
   lets you reuse another manifest's scripts (see `dev-gui` reusing
   `dev/base.sh` + `dev/user.sh`). Defaults to `(setup.sh)` if unset;
   set to `()` to skip provisioning entirely.
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
| `SETUP_SCRIPTS` | `(setup.sh)` | Bash array of script paths. Each is pushed to `/root/<basename>` and run as `bash`, in order. Relative paths resolve against `CONTAINER_DIR`, so `../<other-manifest>/foo.sh` lets one manifest reuse another's scripts. Basenames must be unique across the array. Empty array skips provisioning. |

**Hooks** (all run on the host, all optional, fail-fast on non-zero exit)

| Hook | When | Extra scope |
|---|---|---|
| `hook_pre_launch` | After profile sync + host-prep, before `incus launch` | — |
| `hook_pre_setup` | Once, after launch + devices + network ready, before pushing the first setup script | — |
| `hook_post_setup` | Once, after the last setup script returns, before restart | — |
| `hook_post_launch` | After restart, with `$IP` resolved | `$IP` |

**Variables and helpers exported to hooks**

| Name | Available in | Source |
|---|---|---|
| `NAME` | all hooks | CLI arg — container name |
| `MANIFEST` | all hooks | CLI arg — manifest name |
| `CONTAINER_DIR` | all hooks | Absolute path to `manifests/$MANIFEST/` |
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
