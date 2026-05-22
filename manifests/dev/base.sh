#!/usr/bin/env bash
# Base system setup. Run as root inside the container:
#   bash /root/base.sh
#
# Installs:
#   - CachyOS repos (more packages + v4-optimized builds)
#   - Base toolchain: git, base-devel, sudo, editors, shell utilities
#   - nvidia-utils (must match host driver version)
#
# CachyOS-v4 packages require a host CPU with x86-64-v4 support
# (Zen 4+ / Sapphire Rapids+).

set -euo pipefail

log() { printf '%s => %s\n' "$(date -Iseconds)" "$*" >&2; }

# Packages installed via pacman. Toolchain + headless shell tools only.
# GUI bits live in dev-gui/gui.sh.
PKGS=(
  # Toolchain / shell utilities
  zsh sudo base-devel curl wget openssl git rust go npm uv python-uv
  nano vim parallel pv zstd fzf eza jq miller
  strace perf tealdeer ncdu tmux rsync

  # NVIDIA userspace (must match host driver version)
  nvidia-utils
)

if [[ "$(id -u)" -ne 0 ]]; then
  log "must run as root inside the container"
  exit 1
fi

# pacman post-install hooks (udevadm trigger / systemd-hwdb) fail to write
# /sys/.../uevent in unprivileged containers and make pacman exit 1 even
# though the transaction completed. Install, then verify with `pacman -Q`.
# Note: no `-u` here — a single explicit system upgrade is run once below,
# right after the CachyOS repos are enabled.
pac_install() {
  pacman -Syu --needed --noconfirm "$@" || true
  pacman -Q "$@" >/dev/null
}

if ! pacman -Qi cachyos-keyring >/dev/null 2>&1; then
  log "enabling CachyOS repositories and upgrading to optimized packages"
  pac_install curl tar
  # cachyos-repo.sh calls `pacman-key --recv-keys`; default keyserver is
  # flaky. Pin to keyserver.ubuntu.com (most reliable pgp keyserver).
  if ! grep -q '^keyserver ' /etc/pacman.d/gnupg/gpg.conf 2>/dev/null; then
    echo 'keyserver hkps://keyserver.ubuntu.com' >> /etc/pacman.d/gnupg/gpg.conf
  fi
  tmpd="$(mktemp -d)"
  (
    cd "${tmpd}"
    curl -L -q https://mirror.cachyos.org/cachyos-repo.tar.xz | tar -xJ
    cd cachyos-repo
    # cachyos-repo.sh installs keyring + mirrorlists, then runs `pacman -Syu`.
    yes | ./cachyos-repo.sh --install || true
  )
  rm -rf "${tmpd}"
  pacman -Qi cachyos-keyring >/dev/null
fi

# One-shot system upgrade now that CachyOS repos are enabled. After this
# point, `pac_install` uses `-S` (no further upgrades).
log "system upgrade against arch + cachyos repos"
pacman -Syu --noconfirm

log "installing ${#PKGS[@]} pacman packages"
pac_install "${PKGS[@]}"

# GPU sanity check. Soft warn — fine in headless manifests without a GPU.
if command -v nvidia-smi >/dev/null 2>&1; then
  log "nvidia-smi:"
  nvidia-smi -L || log "WARN: nvidia-smi failed (no GPU passthrough, or driver mismatch with host?)"
fi

log "base setup complete"
