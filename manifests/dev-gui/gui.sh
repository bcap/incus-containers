#!/usr/bin/env bash
# GUI setup. Run as root inside the container:
#   bash /root/gui.sh
#
# Assumes ../dev/base.sh and ../dev/user.sh already ran (CachyOS repos
# enabled, 'user' uid 1000 created).
#
# Installs:
#   - KasmVNC (combined X server + VNC + web client) + fonts
#   - LXQt desktop (lxqt-session on openbox)
#   - Brave browser, alacritty, qt6ct theming
#
# Provides three systemd services so the GUI stack survives restarts:
#   kasmvnc (Xvnc, the combined X+VNC server), wm (lxqt-session),
#   wallpaper (oneshot, renders /home/$USER/.background.png on every boot)
#
# Access:
#   https://<container-ip>:8443/   (web client, self-signed cert, no auth)

set -euo pipefail

log() { printf '%s => %s\n' "$(date -Iseconds)" "$*" >&2; }

USER_UID=1000

# Display + KasmVNC web server.
DISPLAY_NUM=":99"
WEB_PORT="8443"
SCREEN_W=3840
SCREEN_H=2160
SCREEN_D=24

# KasmVNC release. No Arch package exists; the upstream Fedora 41 RPM is
# extracted directly into /. Bumping past Fedora 41's glibc may break this.
KASM_VERSION="1.4.0"

PKGS=(
  # GUI apps
  brave-bin

  # LXQt desktop (openbox is the underlying WM) + fonts
  lxqt-session lxqt-panel lxqt-config lxqt-qtplugin lxqt-themes
  lxqt-runner lxqt-notificationd openbox pcmanfm-qt
  alacritty qt6ct
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

  # Wallpaper generator (imagemagick) + setter (feh, sets the X root window).
  imagemagick feh
)

KASM_RPM="kasmvncserver_fedora_fortyone_${KASM_VERSION}_x86_64.rpm"
KASM_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASM_VERSION}/${KASM_RPM}"

if [[ "$(id -u)" -ne 0 ]]; then
  log "must run as root inside the container"
  exit 1
fi

if ! getent passwd "${USER_UID}" >/dev/null; then
  log "expected uid ${USER_UID} to exist (run dev/user.sh first)"
  exit 1
fi
USER_NAME="$(getent passwd "${USER_UID}" | cut -d: -f1)"
USER_HOME="$(getent passwd "${USER_UID}" | cut -d: -f6)"

# See dev/base.sh for the rationale on the `|| true` + `pacman -Q` dance.
pac_install() {
  pacman -Syu --needed --noconfirm "$@" || true
  pacman -Q "$@" >/dev/null
}

log "installing ${#PKGS[@]} pacman packages"
pac_install "${PKGS[@]}"

# =============================================================================
# Disable xdg-user-dirs
# =============================================================================
# xdg-user-dirs-update is triggered by the session manager (lxqt-session)
# on first login and creates Desktop/Documents/Downloads/Music/Pictures/
# Public/Templates/Videos in $HOME. Useless in a dev container. Must be
# in place *before* the first session starts.
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
# Wallpaper: PNG (re)generated on every container boot with host name, IP and
# instance description. pcmanfm-qt's desktop module is masked (see above), so
# the X root window is what's visible — `feh` paints it. Vars come from
# /etc/incus-vars, written by bin/new at provision time. Wired below as a
# systemd oneshot (wallpaper.service) ordered after kasmvnc + wm.
# =============================================================================

log "installing wallpaper script"

cat >/usr/local/bin/gen-wallpaper <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# NAME, DESCRIPTION, … written by bin/new at provision time.
# shellcheck disable=SC1091
[[ -f /etc/incus-vars ]] && . /etc/incus-vars

name="$(hostname)"
ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
ip="${ip:-unknown}"
description="${DESCRIPTION:-}"

font_size=22
paddingv=5
starth=50
startv=50

out="${HOME}/.background.png"

magick -size 3840x2160 gradient:'#222233-#888899' \
  -font /usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf \
  -pointsize ${font_size} -fill '#CCCCCC' \
  -gravity northwest \
  -annotate +${starth}+$((starth + (font_size + paddingv) * 0 )) "${name}" \
  -annotate +${starth}+$((starth + (font_size + paddingv) * 1 )) "${ip}" \
  -annotate +${starth}+$((starth + (font_size + paddingv) * 3 )) "${description}" \
  "${out}"

feh --no-fehbg --bg-tile "${out}"
EOF

chmod 0755 /usr/local/bin/gen-wallpaper

# =============================================================================
# HTTP :80 redirector → KasmVNC web client. Lets users hit
# `http://<name>.incus` and land on the right URL with the IME flag set.
# Hostname is resolved per-request so container renames track automatically.
# =============================================================================

log "installing vnc-redirect script"

cat >/usr/local/bin/vnc-redirect <<'EOF'
#!/usr/bin/env bash
# Read+discard the HTTP request (headers end at the first blank line),
# then emit a 302 to the KasmVNC web client on this host.
while IFS= read -r line; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && break
done

url="https://$(hostname).incus:8443/vnc.html?enable_ime=true"

printf 'HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' "$url"
EOF

chmod 0755 /usr/local/bin/vnc-redirect

# =============================================================================
# Systemd services (kasmvnc = X+VNC+web, wm = lxqt-session, wallpaper,
# vnc-redirect = :80 → :8443/vnc.html) + DISPLAY in shells
# =============================================================================

log "installing systemd services (kasmvnc, wm, wallpaper)"
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
  -desktop %H \\
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

# Wallpaper as a oneshot. Ordered after wm.service so lxqt-session has had
# a chance to come up, but feh only needs the X server (kasmvnc.service).
# Restart=on-failure with a 1s back-off covers the gap between Xvnc spawning
# and the X socket accepting connections — no polling needed in the script.

cat >/etc/systemd/system/wallpaper.service <<EOF
[Unit]
Description=Container info wallpaper
After=kasmvnc.service wm.service
Requires=kasmvnc.service

[Service]
Type=oneshot
User=${USER_NAME}
Environment=DISPLAY=${DISPLAY_NUM}
Environment=HOME=${USER_HOME}
ExecStart=/usr/local/bin/gen-wallpaper
RemainAfterExit=yes
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/vnc-redirect.service <<'EOF'
[Unit]
Description=HTTP :80 → KasmVNC web client redirector
After=network.target

[Service]
ExecStart=/usr/bin/socat -T 5 TCP-LISTEN:80,reuseaddr,fork EXEC:/usr/local/bin/vnc-redirect
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

log "enabling and starting kasmvnc + wm + wallpaper + vnc-redirect services"
systemctl daemon-reload
systemctl enable kasmvnc.service wm.service wallpaper.service vnc-redirect.service
systemctl restart kasmvnc.service wm.service wallpaper.service vnc-redirect.service

log "gui setup complete"
