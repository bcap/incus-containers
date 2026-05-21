# containers

A personal collection of Incus container definitions and a small launcher
to build them.

The repo is two things:

- A generic launcher (`bin/new`) that composes Incus profiles, runs any
  per-profile host prep, launches a container, and provisions it.
- A growing set of **container manifests** (`manifests/<name>/`), one per
  container type. Currently:
  - **llm-agent** — GUI container for running LLM coding agents with
    browser automation. NVIDIA passthrough, KasmVNC web client.

See `CLAUDE.md` for the full manifest spec and internals.

## Requirements

- Linux host with [Incus](https://linuxcontainers.org/incus/) installed.
- For `llm-agent` specifically: NVIDIA GPU + driver on the host, and a
  modern CPU (Zen 4 / Sapphire Rapids or newer) for CachyOS v4 packages.

## Launch a container

```sh
./bin/new <manifest> <name>
```

Examples:

```sh
./bin/new llm-agent my-agent       # GUI agent container
./bin/new --list                   # show available manifests
./bin/new --help
```

The launcher handles host prep (e.g. subuid/subgid for bind mounts),
syncs Incus profiles from `incus/profiles/`, launches the container, and
runs the manifest's `setup.sh` inside it. Takes a couple of minutes the
first time.

When it finishes you'll see (for `llm-agent`):

```
… => Container 'my-agent' ready.
…    IP:    10.x.y.z
…    Web:   https://10.x.y.z:8443/vnc.html
…    VNC:   vncviewer 10.x.y.z:8443
…    Shell: incus exec my-agent -- sudo -iu agent
```

## Use an llm-agent container

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
incus exec my-agent -- sudo -iu agent
```

**Share a code directory with the host:**

```sh
incus config device add my-agent code disk \
  source=/home/$USER/code \
  path=/home/agent/code \
  shift=true
```

Files appear owned by your user on both sides.

**Reach a web service the agent started** (e.g. a dev server on `:3000`):

```sh
curl http://10.x.y.z:3000/
```

## Manage containers

```sh
incus list                          # see what's running
incus stop my-agent                 # stop
incus start my-agent                # start again
incus delete my-agent --force       # destroy
```

## Add a new container type

1. Create `manifests/<name>/container.sh` with at least `DESCRIPTION`,
   `IMAGE`, `PROFILES`.
2. Optionally add `manifests/<name>/setup.sh` for in-container
   provisioning.
3. If you need a new capability, add a profile under `incus/profiles/`
   (and an optional `<name>.host.sh` sidecar for host prep).

See `CLAUDE.md` for the full spec.
