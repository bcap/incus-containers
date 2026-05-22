#!/usr/bin/env bash
# Provisions a dev-lxqt container. Run as root inside the container:
#   bash /root/setup.sh
#
# Installs:
#   - CachyOS repos (for brave-bin + v4-optimized packages)
#   - KasmVNC (combined X server + VNC + web client) + fonts
#   - LXQt desktop (lxqt-session on openbox)
#   - Brave browser + qterminal
#   - nvidia-utils (must match host driver version)
#   - base toolchain: git, base-devel, sudo
#   - 'user' user (uid 1000, passwordless wheel)
#
# Provides two systemd services so the GUI stack survives restarts:
#   kasmvnc (Xvnc, the combined X+VNC server), wm (lxqt-session)
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
  brave-bin

  # LXQt desktop (openbox is the underlying WM) + fonts
  lxqt-session lxqt-panel lxqt-config lxqt-qtplugin lxqt-themes
  lxqt-runner lxqt-notificationd openbox pcmanfm-qt
  alacritty tmux qt6ct
  noto-fonts ttf-dejavu xorg-fonts-misc
  # Cursor + icon themes. xcursor-themes ships Adwaita (sane default
  # size, so the X fallback cursor stops being a giant chevron).
  # breeze-icons is the icon theme referenced by lxqt.conf; it depends
  # only on qt6-base + glibc, not on KDE Frameworks/Plasma.
  xcursor-themes breeze-icons

  # KasmVNC runtime deps (RPM is dropped onto / and links against these)
  # libarchive provides bsdtar, used to extract the RPM
  libarchive libjpeg-turbo libwebp gnutls openssl libxfont2 pixman
  perl xkeyboard-config xorg-xkbcomp xorg-xauth libdrm xorg-xrdb

  # dbus-launch — LXQt needs a session bus
  dbus

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

# Disable xdg-user-dirs-update (creates Desktop/Documents/Downloads/Music/
# Pictures/Public/Templates/Videos in $HOME on first login). Useless in a
# headless dev container. Must be in place *before* any session starts.
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config"
cat >"${USER_HOME}/.config/user-dirs.conf" <<'EOF'
enabled=False
EOF
cat >"${USER_HOME}/.config/user-dirs.dirs" <<EOF
XDG_DESKTOP_DIR="\$HOME"
XDG_DOCUMENTS_DIR="\$HOME"
XDG_DOWNLOAD_DIR="\$HOME"
XDG_MUSIC_DIR="\$HOME"
XDG_PICTURES_DIR="\$HOME"
XDG_PUBLICSHARE_DIR="\$HOME"
XDG_TEMPLATES_DIR="\$HOME"
XDG_VIDEOS_DIR="\$HOME"
EOF
chown "${USER_NAME}:${USER_NAME}" \
  "${USER_HOME}/.config/user-dirs.conf" \
  "${USER_HOME}/.config/user-dirs.dirs"

# Belt-and-braces: rmdir the default dirs in case anything created them
# before this script ran. Only removes empty dirs.
for d in Desktop Documents Downloads Music Pictures Public Templates Videos Projects; do
  rmdir "${USER_HOME}/${d}" 2>/dev/null || true
done

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
# Brave config
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
# LXQt config: pick a dark theme. lxqt-themes ships Frost (clean dark
# default). Brave + qterminal are XDG .desktop apps, so they appear in the
# panel menu automatically; no extra wiring needed.
# =============================================================================

log "writing LXQt config"
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config/lxqt"

cat >"${USER_HOME}/.config/lxqt/lxqt.conf" <<'EOF'
[General]
theme=leech
icon_theme=breeze-dark

[Qt]
style=Fusion
EOF

# Explicit window_manager (openbox is the default but lxqt-session sometimes
# auto-detects oddly under headless KasmVNC). [Mouse] sets the X cursor
# theme — without it Qt apps draw their own cursor while raw X falls back
# to a huge default chevron (two sizes on the same screen).
cat >"${USER_HOME}/.config/lxqt/session.conf" <<'EOF'
[General]
window_manager=openbox

[Environment]
QT_QPA_PLATFORMTHEME=qt6ct
XCURSOR_THEME=Adwaita
XCURSOR_SIZE=24

[Mouse]
cursor_theme=Adwaita
cursor_size=24
EOF

# X cursor theme is resolved via ~/.icons/default/index.theme (inherits
# chain). Without this, libXcursor returns the legacy bitmap cursor.
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.icons/default"
cat >"${USER_HOME}/.icons/default/index.theme" <<'EOF'
[Icon Theme]
Inherits=Adwaita
EOF

# Xresources: the X server reads Xcursor.theme/size for the *core cursor*
# protocol (used by some Qt widgets' I-beam in qterminal, GTK apps, etc.).
# Without this, those widgets render the legacy 64px bitmap cursor even
# when XCURSOR_SIZE is set in env. Loaded via `xrdb -merge` in wm.service.
cat >"${USER_HOME}/.Xresources" <<'EOF'
Xcursor.theme: Adwaita
Xcursor.size: 24
EOF
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.Xresources"

# panel.conf: seed an explicit plugin layout. Without [panel1] plugins=...
# lxqt-panel runs with a near-empty default and looks broken (just a
# desktop switcher + an unidentified placeholder). Order is left-to-right.
cat >"${USER_HOME}/.config/lxqt/panel.conf" <<'EOF'
[General]
__userfile__=true
iconTheme=breeze-dark

[panel1]
alignment=-1
animation-duration=0
background-color=#1f2329
background-image=
desktop=0
font-color=@Variant(\0\0\0\x43\0\xff\xff\xff\xff\xff\xff\0)
hidable=false
hide-on-overlap=false
iconSize=22
lineCount=1
lockPanel=false
opacity=100
panelSize=34
plugins=mainmenu, quicklaunch, taskbar, spacer, statusnotifier, tray, worldclock, showdesktop
position=Bottom
reserve-space=true
show-delay=0
visible-margin=true
width=100
width-percent=true

[mainmenu]
type=mainmenu

[quicklaunch]
type=quicklaunch
apps\1\desktop=/usr/share/applications/brave-browser.desktop
apps\2\desktop=/usr/share/applications/Alacritty.desktop
apps\3\desktop=/usr/share/applications/pcmanfm-qt.desktop
apps\size=3

[taskbar]
type=taskbar
buttonStyle=IconOnly
showOnlyOneDesktopTasks=false
showOnlyCurrentScreenTasks=false
groupingEnabled=true

[spacer]
type=spacer
size=10
expandable=true

[statusnotifier]
type=statusnotifier

[tray]
type=tray

[worldclock]
type=worldclock
formatType=custom
customFormat=<b>HH:mm:ss</b><br/><font size="-2">yyyy-MM-dd</font>

[showdesktop]
type=showdesktop
EOF

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/lxqt" "${USER_HOME}/.icons"

# Openbox root menu (right-click on desktop). Default at
# /etc/xdg/openbox/menu.xml lists apps that aren't installed in this
# container (gnome-terminal, firefox, gedit, etc.). Seed a minimal menu
# with only what we provide.
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config/openbox"
cat >"${USER_HOME}/.config/openbox/menu.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_menu xmlns="http://openbox.org/3.4/menu">
  <menu id="root-menu" label="Openbox 3">
    <item label="Terminal">
      <action name="Execute"><command>alacritty</command></action>
    </item>
    <item label="Browser">
      <action name="Execute"><command>brave</command></action>
    </item>
    <item label="File Manager">
      <action name="Execute"><command>pcmanfm-qt</command></action>
    </item>
  </menu>
</openbox_menu>
EOF
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/openbox/menu.xml"

# qt6ct: Qt6 platform theme — gives Qt apps a coherent dark palette
# (lxqt-qtplugin alone leaves many widgets light). Seed a Breeze-Dark-ish
# palette + Fusion style. Activated via QT_QPA_PLATFORMTHEME=qt6ct.
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" \
  "${USER_HOME}/.config/qt6ct" "${USER_HOME}/.config/qt6ct/colors"

cat >"${USER_HOME}/.config/qt6ct/colors/dark.conf" <<'EOF'
[ColorScheme]
active_colors=#ffeff0f1, #ff31363b, #ff404040, #ff232629, #ff191b1c, #ff2a2e32, #ffeff0f1, #ffffffff, #ffeff0f1, #ff31363b, #ff232629, #ff1d2023, #ff3daee9, #ffeff0f1, #ff2980b9, #ffeff0f1, #ff31363b, #ffeff0f1, #ff31363b, #ffbf0000, #ff232629, #ffeeeeec
disabled_colors=#ff7f8c8d, #ff31363b, #ff404040, #ff232629, #ff191b1c, #ff2a2e32, #ff7f8c8d, #ffffffff, #ff7f8c8d, #ff31363b, #ff232629, #ff1d2023, #ff3daee9, #ff7f8c8d, #ff2980b9, #ff7f8c8d, #ff31363b, #ff7f8c8d, #ff31363b, #ffbf0000, #ff232629, #ffeeeeec
inactive_colors=#ffeff0f1, #ff31363b, #ff404040, #ff232629, #ff191b1c, #ff2a2e32, #ffeff0f1, #ffffffff, #ffeff0f1, #ff31363b, #ff232629, #ff1d2023, #ff3daee9, #ffeff0f1, #ff2980b9, #ffeff0f1, #ff31363b, #ffeff0f1, #ff31363b, #ffbf0000, #ff232629, #ffeeeeec
EOF

cat >"${USER_HOME}/.config/qt6ct/qt6ct.conf" <<EOF
[Appearance]
custom_palette=true
color_scheme_path=${USER_HOME}/.config/qt6ct/colors/dark.conf
icon_theme=breeze-dark
standard_dialogs=default
style=Fusion

[Interface]
activate_item_on_single_click=1
double_click_interval=400
cursor_flash_time=1000
EOF

chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/qt6ct"

# alacritty: GPU-accelerated terminal. Dark theme + sensible font size.
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config/alacritty"
cat >"${USER_HOME}/.config/alacritty/alacritty.toml" <<'EOF'
[window]
opacity = 1.0
padding = { x = 6, y = 6 }
dynamic_padding = true

[font]
size = 10.0

[font.normal]
family = "Monospace"
style = "Regular"

[colors.primary]
background = "#1f2329"
foreground = "#dcdfe4"

[colors.normal]
black   = "#1f2329"
red     = "#e06c75"
green   = "#98c379"
yellow  = "#e5c07b"
blue    = "#61afef"
magenta = "#c678dd"
cyan    = "#56b6c2"
white   = "#abb2bf"

[colors.bright]
black   = "#5c6370"
red     = "#e06c75"
green   = "#98c379"
yellow  = "#e5c07b"
blue    = "#61afef"
magenta = "#c678dd"
cyan    = "#56b6c2"
white   = "#ffffff"
EOF
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/alacritty"

# Stop pcmanfm-qt from rendering the desktop. In a container its default
# "Places" shortcuts (Computer, Network, Trash) point at non-existent
# mounts and render as broken icons. Mask the XDG autostart entry with
# a user override.
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config/autostart"
cat >"${USER_HOME}/.config/autostart/lxqt-desktop.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Desktop
Exec=pcmanfm-qt --desktop --profile=lxqt
OnlyShowIn=LXQt;
X-LXQt-Module=true
Hidden=true
EOF
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/autostart/lxqt-desktop.desktop"

# Belt-and-braces: if a future tweak re-enables the desktop module, at
# least drop the broken Places shortcuts from its config.
install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config/pcmanfm-qt/lxqt"
cat >"${USER_HOME}/.config/pcmanfm-qt/lxqt/settings.conf" <<'EOF'
[Desktop]
DesktopShortcuts=
HideItems=false
ShowHidden=false
WallpaperMode=color
BgColor=#1f2329
FgColor=#ffffff
EOF
chown -R "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.config/pcmanfm-qt"

# =============================================================================
# Systemd services (kasmvnc = X+VNC+web, wm = lxqt-session) + DISPLAY in shells
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

# LXQt needs a dbus session bus. `dbus-run-session` stays in the foreground
# (unlike `dbus-launch --exit-with-session`, which daemonizes and confuses
# systemd's Type=simple). QT_QPA_PLATFORMTHEME=lxqt is what makes Qt apps
# pick up lxqt-config-appearance's theming.
cat >/etc/systemd/system/wm.service <<EOF
[Unit]
Description=LXQt session
Requires=kasmvnc.service
After=kasmvnc.service

[Service]
User=${USER_NAME}
Environment=DISPLAY=${DISPLAY_NUM}
Environment=HOME=${USER_HOME}
Environment=XDG_RUNTIME_DIR=/tmp/runtime-${USER_NAME}
Environment=QT_QPA_PLATFORMTHEME=qt6ct
Environment=XCURSOR_THEME=Adwaita
Environment=XCURSOR_SIZE=24
ExecStartPre=/usr/bin/install -d -m 0700 -o ${USER_NAME} -g ${USER_NAME} /tmp/runtime-${USER_NAME}
ExecStartPre=/usr/bin/xrdb -merge ${USER_HOME}/.Xresources
ExecStart=/usr/bin/dbus-run-session /usr/bin/startlxqt
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/environment.d/10-display.conf <<EOF
DISPLAY=${DISPLAY_NUM}
EOF

# System-wide cursor env: must be in /etc/environment (read by PAM, every
# login shell, dbus-activated processes) — not just wm.service's
# Environment=, which only covers direct children of lxqt-session.
if ! grep -q '^XCURSOR_THEME=' /etc/environment 2>/dev/null; then
  printf 'XCURSOR_THEME=Adwaita\nXCURSOR_SIZE=24\n' >>/etc/environment
fi

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
