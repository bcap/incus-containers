#!/usr/bin/env bash
# Provisions a dev container. Run as root inside the container:
#   bash /root/setup.sh
#
# Installs:
#   - CachyOS repos (for brave-bin + v4-optimized packages)
#   - KasmVNC (combined X server + VNC + web client) + openbox + tint2 + konsole + fonts
#   - Brave browser
#   - nvidia-utils (must match host driver version)
#   - base toolchain: git, base-devel, sudo
#   - 'user' user (uid 1000, passwordless wheel)
#
# Provides two systemd services so the GUI stack survives restarts:
#   kasmvnc (Xvnc, the combined X+VNC server), wm (openbox)
#
# CachyOS-v4 packages require a host CPU with x86-64-v4 support
# (Zen 4+ / Sapphire Rapids+).
#
# Access:
#   https://<container-ip>:8443/   (web client, self-signed cert, no auth)

set -euo pipefail

log() { printf '%s => %s\n' "$(date -Iseconds)" "$*" >&2; }

# =============================================================================
# User-editable configuration
# =============================================================================

# Unprivileged user created inside the container.
USER_UID=1000
USER_NAME="user"

# Display + KasmVNC web server.
DISPLAY_NUM=":99"
WEB_PORT="8443"
SCREEN_W=1920
SCREEN_H=1080
SCREEN_D=24

# KasmVNC release. No Arch package exists; the upstream Fedora 41 RPM is
# extracted directly into /. Bumping past Fedora 41's glibc may break this.
KASM_VERSION="1.4.0"

# Packages installed via pacman
PKGS=(
  base-devel git sudo curl libarchive wget
  openbox tint2 konsole
  brave-bin
  noto-fonts ttf-dejavu xorg-fonts-misc
  nvidia-utils
  libjpeg-turbo libwebp gnutls openssl libxfont2 pixman perl
  xkeyboard-config xorg-xkbcomp xorg-xauth libdrm
)

# =============================================================================
# Derived values
# =============================================================================

KASM_RPM="kasmvncserver_fedora_fortyone_${KASM_VERSION}_x86_64.rpm"
KASM_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/${KASM_RPM}"

# =============================================================================
# Preflight
# =============================================================================

if [[ "$(id -u)" -ne 0 ]]; then
  log "must run as root inside the container"
  exit 1
fi

# =============================================================================
# Create unprivileged user (passwordless wheel)
# =============================================================================

if ! getent passwd "${USER_UID}" >/dev/null; then
  log "creating user ${USER_NAME} (uid ${USER_UID})"
  useradd -m -u "${USER_UID}" -G wheel "${USER_NAME}"
  passwd -d "${USER_NAME}"
fi
USER_NAME="$(getent passwd "${USER_UID}" | cut -d: -f1)"
USER_HOME="$(getent passwd "${USER_UID}" | cut -d: -f6)"

# =============================================================================
# CachyOS repositories (more packages + optimized builds)
# =============================================================================

# pacman post-install hooks (udevadm trigger / systemd-hwdb) fail to write
# /sys/.../uevent in unprivileged containers and make pacman exit 1 even
# though the transaction completed. Install, then verify with `pacman -Q`.
pac_install() {
  pacman -Syu --needed --noconfirm "$@" || true
  pacman -Q "$@" >/dev/null
}

if ! pacman -Qi cachyos-keyring >/dev/null 2>&1; then
  log "enabling CachyOS repositories"
  pac_install curl tar
  tmpd="$(mktemp -d)"
  (
    cd "${tmpd}"
    curl -L -q https://mirror.cachyos.org/cachyos-repo.tar.xz | tar -xJ
    cd cachyos-repo
    yes | ./cachyos-repo.sh --install
  )
  rm -rf "${tmpd}"
  pacman -Qi cachyos-keyring >/dev/null
fi

# =============================================================================
# Install base packages
# =============================================================================

log "installing ${#PKGS[@]} pacman packages"
pac_install "${PKGS[@]}"

# =============================================================================
# Passwordless sudo for wheel
# =============================================================================

log "configuring passwordless sudo for wheel"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/wheel-nopass
chmod 0440 /etc/sudoers.d/wheel-nopass

# =============================================================================
# Install KasmVNC
# =============================================================================

if ! /usr/bin/Xvnc -version 2>&1 | grep -qi kasm; then
  log "installing KasmVNC ${KASM_VERSION}"
  tmpd="$(mktemp -d)"
  (
    cd "${tmpd}"
    curl -fsSL -o "${KASM_RPM}" "${KASM_URL}"
    bsdtar -xpf "${KASM_RPM}" -C /
  )
  rm -rf "${tmpd}"
  /usr/bin/Xvnc -version 2>&1 | grep -qi kasm
fi

log "writing VNC config + TLS cert"
install -d -m 0700 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.vnc"

if [[ ! -f "${USER_HOME}/.vnc/self.pem" ]]; then
  sudo -u "${USER_NAME}" openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${USER_HOME}/.vnc/self.pem" \
    -out "${USER_HOME}/.vnc/self.pem" \
    -days 3650 -subj "/CN=dev-container" 2>/dev/null
  chmod 0600 "${USER_HOME}/.vnc/self.pem"
  chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.vnc/self.pem"
fi

cat >"${USER_HOME}/.vnc/kasmvnc.yaml" <<EOF
network:
  websocket_port: ${WEB_PORT}
  ssl:
    require_ssl: true
desktop:
  resolution:
    width: ${SCREEN_W}
    height: ${SCREEN_H}
  allow_resize: true
encoding:
  max_frame_rate: 60
  jpeg_quality: 7
  webp_quality: 7
runtime_configuration:
  allow_client_to_override_kasm_server_settings: true
EOF
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.vnc/kasmvnc.yaml"
chmod 0644 "${USER_HOME}/.vnc/kasmvnc.yaml"

# =============================================================================
# Brave config (disable kwallet — no KDE session in the container)
# =============================================================================

log "writing Brave config"
install -d -m 0700 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config"
cat >"${USER_HOME}/.config/brave-flags.conf" <<'EOF'
--password-store=basic
EOF
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/brave-flags.conf"

# =============================================================================
# Openbox: autostart (tint2) + right-click menu
# =============================================================================

log "writing Openbox config"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config/openbox"
cat >"${USER_HOME}/.config/openbox/autostart" <<'EOF'
tint2 &
EOF
chmod 0755 "${USER_HOME}/.config/openbox/autostart"

cat >"${USER_HOME}/.config/openbox/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Openbox">
    <item label="Brave">
      <action name="Execute"><command>brave</command></action>
    </item>
    <item label="Konsole">
      <action name="Execute"><command>konsole</command></action>
    </item>
  </menu>
</openbox_menu>
EOF
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/openbox"

# =============================================================================
# Systemd services (kasmvnc = X+VNC+web, wm = openbox) + DISPLAY in shells
# =============================================================================

log "installing systemd services (kasmvnc, wm)"
install -d -m 0755 /etc/systemd/system /etc/environment.d /etc/profile.d

cat >/etc/systemd/system/kasmvnc.service <<EOF
[Unit]
Description=KasmVNC Xvnc (combined X + VNC + web client)
After=network.target

[Service]
User=${USER_NAME}
Environment=HOME=${USER_HOME}
WorkingDirectory=${USER_HOME}
ExecStart=/usr/bin/Xvnc ${DISPLAY_NUM} \\
  -geometry ${SCREEN_W}x${SCREEN_H} \\
  -depth ${SCREEN_D} \\
  -websocketPort ${WEB_PORT} \\
  -interface 0.0.0.0 \\
  -sslOnly \\
  -cert ${USER_HOME}/.vnc/self.pem \\
  -httpd /usr/share/kasmvnc/www \\
  -SecurityTypes None \\
  -disableBasicAuth \\
  -FrameRate 60
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/wm.service <<EOF
[Unit]
Description=Openbox window manager
Requires=kasmvnc.service
After=kasmvnc.service

[Service]
User=${USER_NAME}
Environment=DISPLAY=${DISPLAY_NUM}
ExecStart=/usr/bin/openbox-session
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/environment.d/10-display.conf <<EOF
DISPLAY=${DISPLAY_NUM}
EOF

cat >/etc/profile.d/display.sh <<EOF
export DISPLAY=${DISPLAY_NUM}
EOF
chmod 0644 /etc/profile.d/display.sh

log "enabling and starting kasmvnc + wm services"
systemctl daemon-reload
systemctl enable kasmvnc.service wm.service
systemctl restart kasmvnc.service wm.service

# =============================================================================
# GPU sanity check
# =============================================================================

if command -v nvidia-smi >/dev/null 2>&1; then
  log "nvidia-smi:"
  nvidia-smi -L || log "WARN: nvidia-smi failed (driver mismatch with host?)"
fi

log "provisioning complete"
