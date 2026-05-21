#!/usr/bin/env bash
# Provisions a llm-agent container. Run as root inside the container:
#   incus exec <name> -- bash /root/setup.sh
#
# Installs:
#   - CachyOS repos (for brave-bin + v4-optimized packages)
#   - Xvfb + openbox + tint2 + x11vnc + konsole + fonts
#   - Brave browser
#   - nvidia-utils (must match host driver version)
#   - base toolchain: git, base-devel, sudo
#   - 'agent' user (uid 1000, passwordless wheel)
#
# Provides three systemd services so the GUI stack survives restarts:
#   agent-xvfb, agent-wm, agent-vnc
#
# CachyOS-v4 packages require a host CPU with x86-64-v4 support
# (Zen 4+ / Sapphire Rapids+).

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
VNC_PORT="5900"
SCREEN="1920x1080x24"

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
PKGS=(
  base-devel git sudo
  xorg-server-xvfb openbox tint2 x11vnc konsole
  brave-bin
  noto-fonts ttf-dejavu
  nvidia-utils
)
pac -Sy --needed --noconfirm "${PKGS[@]}"
pacman -Q "${PKGS[@]}" >/dev/null

# --- Passwordless wheel sudo (sudoers.d ships with the sudo package) ---
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/wheel-nopass
chmod 0440 /etc/sudoers.d/wheel-nopass

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

cat >/etc/systemd/system/agent-xvfb.service <<EOF
[Unit]
Description=Xvfb virtual framebuffer for llm-agent container
After=network.target

[Service]
User=${USER_NAME}
ExecStart=/usr/bin/Xvfb ${DISPLAY_NUM} -screen 0 ${SCREEN} -ac -nolisten tcp
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/agent-wm.service <<EOF
[Unit]
Description=Openbox window manager for llm-agent container
Requires=agent-xvfb.service
After=agent-xvfb.service

[Service]
User=${USER_NAME}
Environment=DISPLAY=${DISPLAY_NUM}
ExecStart=/usr/bin/openbox-session
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/agent-vnc.service <<EOF
[Unit]
Description=x11vnc for llm-agent container (reachable on incusbr0:${VNC_PORT})
Requires=agent-xvfb.service
After=agent-xvfb.service

[Service]
User=${USER_NAME}
Environment=DISPLAY=${DISPLAY_NUM}
ExecStart=/usr/bin/x11vnc -display ${DISPLAY_NUM} -forever -shared -rfbport ${VNC_PORT} -nopw -repeat
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
systemctl enable --now agent-xvfb.service agent-wm.service agent-vnc.service

# --- Sanity: GPU visible? ---
if command -v nvidia-smi >/dev/null 2>&1; then
  echo "--- nvidia-smi ---"
  nvidia-smi -L || echo "WARN: nvidia-smi failed (driver mismatch with host?)"
fi

echo
echo "Provisioning complete."
