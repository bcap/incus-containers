# llm-agent

A sandbox container for running LLM tooling / coding agents.

Each container gives the agent its own:

- **GPU** — NVIDIA passthrough, so local models run accelerated.
- **Desktop + browser** — A minimal Openbox/X session you can access live through VNC
- **Network** — any web service the agent runs is reachable from your
  host at `<container-ip>:<port>`.
- **Workspace** — bind-mount a host directory so files round-trip
  cleanly between you and the agent.

## Requirements

- Linux host with [Incus](https://linuxcontainers.org/incus/) installed.
- NVIDIA GPU + driver on the host.
- A modern CPU (Zen 4 / Sapphire Rapids or newer).

## Create a container

```sh
./new.sh my-agent
```

That's it. The script handles one-time host setup, the Incus profile,
and provisions the container with everything it needs. Takes a couple
of minutes the first time.

When it finishes you'll see something like:

```
Container 'my-agent' is up.
  IP:     10.x.y.z
  Web:    https://10.x.y.z:8443/vnc.html   (no auth)
  Shell:  incus exec my-agent -- sudo -iu agent
```

## Use it

**Watch the desktop** — open the web client in any browser (self-signed
cert; accept the warning):

```
https://10.x.y.z:8443/vnc.html
```

Or use a native client against the same port:

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

**Reach a web service the agent started** (e.g. a dev server on :3000):

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

## Help

```sh
./new.sh --help
```

For internals, see `CLAUDE.md`.
