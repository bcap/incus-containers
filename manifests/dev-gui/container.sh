# shellcheck shell=bash
# dev-gui: GUI development container (KasmVNC + LXQt + Brave, NVIDIA
# passthrough). Builds on top of the headless `dev` manifest's base+user
# setup scripts. Sourced by bin/new on the host.

DESCRIPTION="GUI dev container (KasmVNC + LXQt + Brave, NVIDIA passthrough)"
IMAGE="images:archlinux"
PROFILES=(gpu-nvidia bind-mountable)

CONFIG=(
  limits.cpu=8
  limits.memory=16GiB
  security.privileged=false
  security.nesting=false
  boot.autostart=false
)

# Bind mounts are user-specific (host paths). Document in README; users
# add them post-launch with `incus config device add`.
DEVICES=()

# Reuse dev's base + user setup, then layer the GUI on top. Relative paths
# resolve against this manifest's directory.
SETUP_SCRIPTS=(
  ../dev/base.sh
  ../dev/user.sh
  gui.sh
)

hook_post_launch() {
  local port=8443
  log "Container '${NAME}' ready."
  log "  IP:     ${IP}"
  log "  DNS:    ${NAME}.incus"
  log "  WebVNC: https://${NAME}.incus:${port}/vnc.html?enable_ime=true"
  log "  Shell:  incus exec ${NAME} -- sudo -iu user"
}
