# shellcheck shell=bash
# dev: GUI development container (KasmVNC + LXQt + Brave, NVIDIA passthrough).
# Sourced by bin/new on the host.

DESCRIPTION="GUI development container (KasmVNC + LXQt + Brave, NVIDIA passthrough)"
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

SETUP_SCRIPT="setup.sh"

hook_post_launch() {
  local port=8443
  log "Container '${NAME}' ready."
  log "  IP:    ${IP}"
  log "  Web:   https://${IP}:${port}/vnc.html?enable_ime=true"
  log "  VNC:   vncviewer ${IP}:${port}"
  log "  Shell: incus exec ${NAME} -- sudo -iu user"
}
