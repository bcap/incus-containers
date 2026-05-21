#!/usr/bin/env bash
# Provisions a llm-agent container. Run as root inside the container:
#   incus exec <name> -- bash /root/setup.sh
#
# Installs:
#   - CachyOS repos (for brave-bin + v4-optimized packages)
#   - KasmVNC (combined X server + VNC + web client) + openbox + tint2 + konsole + fonts
#   - Brave browser
#   - nvidia-utils (must match host driver version)
#   - base toolchain: git, base-devel, sudo
#   - 'agent' user (uid 1000, passwordless wheel)
#
# Provides two systemd services so the GUI stack survives restarts:
#   agent-kasmvnc (Xvnc, the combined X+VNC server), agent-wm (openbox)
#
# CachyOS-v4 packages require a host CPU with x86-64-v4 support
# (Zen 4+ / Sapphire Rapids+).
#
# Access:
#   https://<container-ip>:8443/   (web client, self-signed cert, no auth)

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root inside the container." >&2
  exit 1
fi

USER_UID=1000
USER_NAME="agent"

# --- User: uid 1000, passwordless wheel ---
if ! getent passwd "${USER_UID}" >/dev/null; then
  useradd -m -u "${USER_UID}" -G wheel "${USER_NAME}"
  passwd -d "${USER_NAME}"
fi
USER_NAME="$(getent passwd "${USER_UID}" | cut -d: -f1)"
USER_HOME="$(getent passwd "${USER_UID}" | cut -d: -f6)"

DISPLAY_NUM=":99"
WEB_PORT="8443"
SCREEN_W=1920
SCREEN_H=1080
SCREEN_D=24

# KasmVNC release (upstream binary RPM, repacked onto Arch).
KASM_VERSION="1.4.0"
KASM_RPM="kasmvncserver_fedora_fortyone_${KASM_VERSION}_x86_64.rpm"
KASM_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/${KASM_RPM}"

# pacman post-install hooks (udevadm trigger / systemd-hwdb) fail to write
# /sys/.../uevent in unprivileged containers and make pacman exit 1 even
# though the transaction completed. Wrap pacman so set -e doesn't trip,
# then verify installed packages explicitly.
pac() { pacman "$@" || true; }

# --- CachyOS repos (idempotent: cachyos-keyring as marker) ---
if ! pacman -Qi cachyos-keyring >/dev/null 2>&1; then
  pac -Sy --needed --noconfirm wget tar
  pacman -Q wget tar >/dev/null
  tmpd="$(mktemp -d)"
  (
    cd "${tmpd}"
    wget -q https://mirror.cachyos.org/cachyos-repo.tar.xz
    tar xf cachyos-repo.tar.xz
    cd cachyos-repo
    yes | ./cachyos-repo.sh --install || true
  )
  rm -rf "${tmpd}"
  pacman -Qi cachyos-keyring >/dev/null
fi

# --- Packages ---
# KasmVNC runtime deps: libjpeg-turbo, libwebp, gnutls, openssl, libxfont2,
# pixman, perl, xkeyboard-config, xorg-xkbcomp, xorg-xauth, libdrm.
# libarchive provides bsdtar for RPM extraction.
PKGS=(
  base-devel git sudo curl libarchive
  openbox tint2 konsole
  brave-bin
  noto-fonts ttf-dejavu xorg-fonts-misc
  nvidia-utils
  libjpeg-turbo libwebp gnutls openssl libxfont2 pixman perl
  xkeyboard-config xorg-xkbcomp xorg-xauth libdrm
)
pac -Sy --needed --noconfirm "${PKGS[@]}"
pacman -Q "${PKGS[@]}" >/dev/null

# --- Passwordless wheel sudo (sudoers.d ships with the sudo package) ---
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/wheel-nopass
chmod 0440 /etc/sudoers.d/wheel-nopass

# --- KasmVNC: install by extracting upstream Fedora 41 RPM onto Arch ---
# Idempotent: skip if /usr/bin/Xvnc reports KasmVNC.
if ! /usr/bin/Xvnc -version 2>&1 | grep -qi kasm; then
  echo "[setup] Installing KasmVNC ${KASM_VERSION}..."
  tmpd="$(mktemp -d)"
  (
    cd "${tmpd}"
    curl -fsSL -o "${KASM_RPM}" "${KASM_URL}"
    bsdtar -xpf "${KASM_RPM}" -C /
  )
  rm -rf "${tmpd}"
  /usr/bin/Xvnc -version 2>&1 | grep -qi kasm
fi

# --- KasmVNC config (user-scoped under ~agent/.vnc) ---
# Passwordless: -SecurityTypes None disables RFB auth, -disableBasicAuth
# (in the systemd unit below) disables the websocket HTTP BasicAuth gate.
install -d -m 0700 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.vnc"

# Self-signed TLS cert for the websocket layer. The `vncserver` perl wrapper
# auto-generates one, but we run Xvnc directly under systemd, so do it here.
if [[ ! -f "${USER_HOME}/.vnc/self.pem" ]]; then
  sudo -u "${USER_NAME}" openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${USER_HOME}/.vnc/self.pem" \
    -out "${USER_HOME}/.vnc/self.pem" \
    -days 3650 -subj "/CN=llm-agent-container" 2>/dev/null
  chmod 0600 "${USER_HOME}/.vnc/self.pem"
  chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.vnc/self.pem"
fi

# Minimal server config (YAML). Explicit beats surprises.
cat >"${USER_HOME}/.vnc/kasmvnc.yaml" <<EOF
network:
  websocket_port: ${WEB_PORT}
  ssl:
    require_ssl: true
    # No pem_certificate/pem_key: KasmVNC auto-generates a self-signed cert
    # at ~/.vnc/self.pem on first start.
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

# --- Brave: skip kwallet/keyring integration (not available in container) ---
install -d -m 0700 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config"
cat >"${USER_HOME}/.config/brave-flags.conf" <<'EOF'
--password-store=basic
EOF
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/brave-flags.conf"

# --- Openbox: autostart tint2 + minimal right-click menu (Brave, Konsole) ---
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

# --- systemd units for the display stack ---
install -d -m 0755 /etc/systemd/system /etc/environment.d /etc/profile.d

# Xvnc is KasmVNC's combined X server + VNC + websocket/web server.
# -interface 0.0.0.0 binds websocket on all interfaces (reachable via incusbr0).
# Passwordless: -SecurityTypes None (no RFB auth) + -disableBasicAuth (no web auth).
cat >/etc/systemd/system/agent-kasmvnc.service <<EOF
[Unit]
Description=KasmVNC Xvnc (combined X + VNC + web client) for llm-agent container
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

cat >/etc/systemd/system/agent-wm.service <<EOF
[Unit]
Description=Openbox window manager for llm-agent container
Requires=agent-kasmvnc.service
After=agent-kasmvnc.service

[Service]
User=${USER_NAME}
Environment=DISPLAY=${DISPLAY_NUM}
ExecStart=/usr/bin/openbox-session
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/environment.d/10-agent-display.conf <<EOF
DISPLAY=${DISPLAY_NUM}
EOF

cat >/etc/profile.d/agent-display.sh <<EOF
export DISPLAY=${DISPLAY_NUM}
EOF
chmod 0644 /etc/profile.d/agent-display.sh

systemctl daemon-reload
# Remove old units from prior (Xvfb + x11vnc) layout if present.
systemctl disable --now agent-xvfb.service agent-vnc.service 2>/dev/null || true
rm -f /etc/systemd/system/agent-xvfb.service /etc/systemd/system/agent-vnc.service
systemctl daemon-reload

systemctl enable agent-kasmvnc.service agent-wm.service
# Restart so unit-file changes take effect on re-provisioning runs.
systemctl restart agent-kasmvnc.service agent-wm.service

# --- Sanity: GPU visible? ---
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "--- nvidia-smi ---"
  nvidia-smi -L || echo "WARN: nvidia-smi failed (driver mismatch with host?)"
fi

echo
echo "Provisioning complete."
echo "Web client: https://<container-ip>:${WEB_PORT}/vnc.html  (no auth)"
