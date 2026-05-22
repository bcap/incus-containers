# shellcheck shell=bash
# dev: headless development container (base toolchain + 'user' uid 1000,
# NVIDIA passthrough). Sourced by bin/new on the host.
#
# For a GUI desktop on top of this, see manifests/dev-gui/.

DESCRIPTION="Headless dev container (base toolchain, zsh, NVIDIA passthrough)"
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

SETUP_SCRIPTS=(base.sh user.sh)

hook_post_launch() {
  log "Container '${NAME}' ready."
  log "  IP:     ${IP}"
  log "  DNS:    ${NAME}.incus"
  log "  Shell:  incus exec ${NAME} -- sudo -iu user"
}
