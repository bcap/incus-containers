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
SCREEN_W=3840
SCREEN_H=2160
SCREEN_D=24

# KasmVNC release. No Arch package exists; the upstream Fedora 41 RPM is
# extracted directly into /. Bumping past Fedora 41's glibc may break this.
KASM_VERSION="1.4.0"

# Packages installed via pacman
PKGS=(
  # Toolchain / shell utilities
  zsh sudo base-devel curl wget openssl git rust go npm uv python-uv
  nano vim parallel pv zstd fzf eza jq miller
  strace perf tealdeer ncdu

  # GUI apps
  konsole brave-bin

  # Window manager + panel + fonts (Arch base ships no fonts)
  openbox tint2
  noto-fonts ttf-dejavu xorg-fonts-misc

  # KasmVNC runtime deps (RPM is dropped onto / and links against these)
  # libarchive provides bsdtar, used to extract the RPM
  libarchive libjpeg-turbo libwebp gnutls openssl libxfont2 pixman
  perl xkeyboard-config xorg-xkbcomp xorg-xauth libdrm

  # NVIDIA userspace (must match host driver version)
  nvidia-utils
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
# CachyOS repositories (more packages + optimized builds)
# =============================================================================

# pacman post-install hooks (udevadm trigger / systemd-hwdb) fail to write
# /sys/.../uevent in unprivileged containers and make pacman exit 1 even
# though the transaction completed. Install, then verify with `pacman -Q`.
# Note: no `-u` here — a single explicit system upgrade is run once below,
# right after the CachyOS repos are enabled.
pac_install() {
  pacman -Syu --needed --noconfirm "$@" || true
  pacman -Q "$@" >/dev/null
}

# Arch image ships a single-entry mirrorlist (mirrors.kernel.org) that has
# been observed 301-ing to a 404. Swap to the geo-routed pkgbuild.com mirror
# before any `pacman -Sy`.
# if ! grep -q geo.mirror.pkgbuild.com /etc/pacman.d/mirrorlist; then
#   log "swapping pacman mirrorlist to geo.mirror.pkgbuild.com"
#   echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' > /etc/pacman.d/mirrorlist
# fi

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

# =============================================================================
# Install base packages
# =============================================================================

log "installing ${#PKGS[@]} pacman packages"
pac_install "${PKGS[@]}"

# =============================================================================
# Create unprivileged user + passwordless wheel
# =============================================================================

if ! getent passwd "${USER_UID}" >/dev/null; then
  log "creating user ${USER_NAME} (uid ${USER_UID})"
  useradd -m -u "${USER_UID}" -G wheel "${USER_NAME}"
  passwd -d "${USER_NAME}"
fi
USER_NAME="$(getent passwd "${USER_UID}" | cut -d: -f1)"
USER_HOME="$(getent passwd "${USER_UID}" | cut -d: -f6)"

log "configuring passwordless sudo for wheel"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" >/etc/sudoers.d/wheel-nopass
chmod 0440 /etc/sudoers.d/wheel-nopass

# =============================================================================
# Default user shell: zsh + oh-my-zsh + custom prompt
# =============================================================================

log "installing oh-my-zsh for ${USER_NAME}"
if [[ ! -d "${USER_HOME}/.oh-my-zsh" ]]; then
  runuser -l "${USER_NAME}" -c \
    'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc'
fi

log "writing ${USER_NAME} .zshrc"

cat >"${USER_HOME}/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
source $ZSH/oh-my-zsh.sh

export PATH="$HOME/bin:$HOME/.local/bin:$HOME/go/bin:$HOME/.cargo/bin:$PATH"

alias -g H='| head -n 20'
alias -g T='| tail -n 20'
alias -g L='| less'
alias -g S='| sort'
alias -g SN='| sort -n'
alias -g SU='| sort | uniq -c'
alias -g CT='| column -t'
alias -g NL='| wc -l'
alias -g N='> /dev/null 2>&1'

alias ls='eza --color=auto --icons=auto'
alias ll='ls -lhg'
alias la='ll -A'
alias lt='ll --tree --level=2'

alias diff='diff -u'
alias grep='grep --color'
alias tmp='cd $(mktemp -d)'

function _prompt() {
    local EXIT_CODE="$?"
    local EXIT_CODE_OK_C=${FG[240]}
    local EXIT_CODE_NOK_C=${FG[009]}
    local EXIT_CODE_C="$EXIT_CODE_OK_C"
    if [[ ! "$EXIT_CODE" -eq 0 ]]; then
        EXIT_CODE_C="$EXIT_CODE_NOK_C"
    fi

    local DATE="$(date +%H:%M:%S)"
    local DATE_C=${FG[247]}

    local USER="%n"
    local USER_C=${FG[208]}

    local AT="@"
    local AT_C=${FG[034]}

    local HOSTNAME="%m"
    local HOSTNAME_C=${FG[208]}

    local CWD="%~"
    local CWD_C=${FG[034]}

    local SHELL_MARKER="%#"
    local SHELL_MARKER_C=${FG[255]}

    echo -e -n "${EXIT_CODE_C}${EXIT_CODE} ${DATE_C}${DATE} ${USER_C}${USER}${AT_C}${AT}${HOSTNAME_C}${HOSTNAME} ${CWD_C}${CWD}\n"
    echo -e -n "${SHELL_MARKER_C}${SHELL_MARKER} "
}
setopt PROMPT_SUBST
PROMPT='$(_prompt)'
EOF

chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.zshrc"
chmod 0644 "${USER_HOME}/.zshrc"

if [[ "$(getent passwd "${USER_NAME}" | cut -d: -f7)" != "/usr/bin/zsh" ]]; then
  log "setting default shell for ${USER_NAME} to zsh"
  chsh -s /usr/bin/zsh "${USER_NAME}"
fi

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
  runuser -l "${USER_NAME}" -c \
    "openssl req -x509 -nodes -newkey rsa:2048 -keyout .vnc/self.pem -out .vnc/self.pem -days 3650 -subj /CN=dev-container 2>/dev/null"
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
  max_resolution:
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
--no-first-run
--no-default-browser-check
--force-dark-mode
--enable-features=WebUIDarkMode
EOF

chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/brave-flags.conf"

# Managed policies: skip first-run nags, disable sign-in / rewards / AI /
# telemetry. Applied system-wide, read on every startup. Inspect at
# brave://policy.
install -d -m 0755 /etc/brave/policies/managed
cat >/etc/brave/policies/managed/dev.json <<'EOF'
{
  "DefaultBrowserSettingEnabled": false,
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "MetricsReportingEnabled": false,
  "SearchSuggestEnabled": false,
  "PasswordManagerEnabled": false,
  "SafeBrowsingProtectionLevel": 0,
  "PromotionalTabsEnabled": false,
  "BraveRewardsDisabled": true,
  "BraveWalletDisabled": true,
  "BraveVPNDisabled": true,
  "BraveAIChatEnabled": false,
  "BraveTalkDisabled": true,
  "BraveNewsDisabled": true,
  "BraveP3AEnabled": false,
  "BraveStatsPingEnabled": false,
  "TorDisabled": true,
  "IPFSEnabled": false
}
EOF
chmod 0644 /etc/brave/policies/managed/dev.json

# =============================================================================
# Konsole: dark color scheme (no Plasma in container to provide one)
# =============================================================================

log "writing Konsole profile + default config"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" \
  "${USER_HOME}/.local/share/konsole" "${USER_HOME}/.config"

cat >"${USER_HOME}/.local/share/konsole/Dev.profile" <<'EOF'
[General]
Name=Dev
Parent=FALLBACK/
Command=/bin/zsh

[Appearance]
ColorScheme=Breeze

[Scrolling]
HistoryMode=1
HistorySize=100000
EOF

cat >"${USER_HOME}/.config/konsolerc" <<'EOF'
[Desktop Entry]
DefaultProfile=Dev.profile

[UiSettings]
ColorScheme=BreezeDark
EOF

chown -R "${USER_NAME}:${USER_NAME}" \
  "${USER_HOME}/.local" "${USER_HOME}/.config/konsolerc"

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
# tint2: override task button mouse bindings (BunsenLabs convention).
# tint2 default right-click = close — easy footgun. Remap to safer actions.
# =============================================================================

log "writing tint2 config"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config/tint2"

cat >"${USER_HOME}/.config/tint2/tint2rc" <<'EOF'
task_mouse_middle = close
task_mouse_right = toggle_iconify
task_mouse_scroll_up = prev_task
task_mouse_scroll_down = next_task
EOF

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/tint2"

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
