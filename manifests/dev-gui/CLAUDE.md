# dev-gui container specifics

Notes future-you will need when editing `gui.sh` or `container.sh` in
this directory. `dev-gui` is `dev` (CachyOS + base toolchain + `user`)
plus a KasmVNC + LXQt + Brave desktop on top.

`container.sh` declares `SETUP_SCRIPTS=(../dev/base.sh ../dev/user.sh
gui.sh)` — the first two are reused from the headless `dev` manifest
via relative paths. Edit those in `manifests/dev/`, not here.

The desktop layer is LXQt (openbox is still the WM underneath); LXQt
ships a coherent default panel + session manager + theme system so we
don't hand-roll the openbox+tint2 stack.

## GUI specifics

- **Display stack** is two systemd services owned by uid 1000:
  `kasmvnc.service` (KasmVNC's combined X+VNC+web on `:8443`,
  passwordless via `-SecurityTypes None -disableBasicAuth`) and
  `wm.service` running `dbus-launch --exit-with-session
  /usr/bin/startlxqt`. `startlxqt` spawns `lxqt-session`, which in turn
  starts openbox + lxqt-panel + lxqt-notificationd + pcmanfm-qt.
- **dbus session bus** is required by lxqt-session (config writers,
  notificationd, panel). `dbus-launch --exit-with-session` provides one
  scoped to the lxqt-session lifetime; no separate user systemd unit.
- **XDG user-dirs disabled** in `gui.sh` *before* the first session
  starts (lxqt-session is what triggers `xdg-user-dirs-update`).
  `~/.config/user-dirs.conf` sets `enabled=False`;
  `~/.config/user-dirs.dirs` points every XDG dir at `$HOME` itself.
  Belt-and-braces: `rmdir` the defaults (only empties, so safe to
  rerun). Lives here, not in `../dev/user.sh`, because nothing in the
  headless container creates these dirs in the first place.
- **XDG_RUNTIME_DIR** is pre-created by `ExecStartPre` (LXQt and Qt6 sulk
  if it's missing).
- **Resolution** is dynamic: initial geometry `SCREEN_W`x`SCREEN_H`
  (default 3840x2160) acts as the cap; KasmVNC's "Remote Resizing"
  (web UI > Settings > Display) lets the client downscale to fit the
  browser viewport via RandR. `max_resolution` in `kasmvnc.yaml`
  enforces the upper bound;
  `allow_client_to_override_kasm_server_settings: true` lets the
  client request resizes at runtime.
- **KasmVNC install path:** no Arch package, no generic tarball. The
  setup script downloads the upstream Fedora 41 RPM and extracts with
  `bsdtar -xpf <rpm> -C /`. Runtime deps come from pacman. Fragile to
  KasmVNC bumping glibc requirements beyond Fedora 41 — revisit if
  install breaks.
- **NVIDIA** via the `gpu-nvidia` profile (`gputype: physical` +
  `nvidia.driver.capabilities: all`). `nvidia-utils` is installed by
  `../dev/base.sh`. `nvidia.runtime: true` would be cleaner but
  currently fails at mount-hook time on this host (Incus 7.0 +
  libnvidia-container 1.19).
- **KasmVNC IME mode** is a *client-side only* toggle (`enable_ime` in
  the browser's localStorage, default `false`). There is no server YAML
  key for it — the upstream KasmVNC config has no `keyboard.ime_mode`.
  Force it on for first connect via the URL query parameter
  `?enable_ime=true` (read by `initSetting` via `WebUtil.getConfigVar`,
  then persisted to localStorage). `hook_post_launch` in `container.sh`
  prints the URL with that param appended. Required when the host uses
  a dead-key layout (e.g. `us(alt-intl)` for Portuguese accents):
  without it the browser drops `Dead` keysyms and `~`, `^`, `` ` ``
  never reach the server.
- **Theming**: `~/.config/lxqt/lxqt.conf` sets `theme=leech` (deepest
  dark shipped by `lxqt-themes`) + `icon_theme=breeze-dark` +
  `style=Fusion`. Qt widgets are themed by `qt6ct` (not lxqt-qtplugin):
  `QT_QPA_PLATFORMTHEME=qt6ct` is exported by `wm.service` and by
  `session.conf`'s `[Environment]`. The qt6ct palette is seeded at
  `~/.config/qt6ct/colors/dark.conf` (Breeze-Dark-ish active/disabled/
  inactive triplets) and referenced from `~/.config/qt6ct/qt6ct.conf`'s
  `color_scheme_path`. Do NOT add a `[Fonts]` section there — qt6ct
  encodes font as a Qt QVariant binary blob; hand-writing it produces
  garbled text with strikeout/underline flags set. Leave fonts at Qt
  defaults or edit via the qt6ct GUI.
- **App menu**: lxqt-panel's main menu is XDG-driven. Brave (`brave-bin`)
  and alacritty install `.desktop` files into `/usr/share/applications/`
  and appear automatically; no manual menu wiring.
- **Openbox root menu (desktop right-click)**: default at
  `/etc/xdg/openbox/menu.xml` lists apps not installed here
  (gnome-terminal, firefox, gedit). Override with a minimal
  `~/.config/openbox/menu.xml` containing only Terminal / Browser /
  File Manager. Reload with `openbox --reconfigure`.
- **Panel layout is load-bearing**: lxqt-panel writes an almost-empty
  `panel.conf` on first launch (no `[panel1]` section, no `plugins=`),
  which renders as a near-blank bar with just a desktop switcher. We
  seed `~/.config/lxqt/panel.conf` with an explicit `[panel1]` +
  `plugins=mainmenu, quicklaunch, taskbar, spacer, statusnotifier, tray,
  worldclock, showdesktop`. lxqt-panel preserves these on first run
  (re-saves the file but keeps the keys). Each plugin needs its own
  `[<name>]` section with `type=<name>` for lxqt-panel to instantiate
  it.
- **X cursor theme is required and four-pronged**. Without it, raw X
  falls back to a giant bitmap cursor while Qt apps draw their own
  smaller one, and qterminal-style I-beam widgets use yet a third size
  (they go through the X *core cursor* protocol, which doesn't read
  `XCURSOR_SIZE`). All four pieces are needed:
  1. `xcursor-themes` package (ships `Adwaita`, ~3 MiB, no KDE deps).
  2. `~/.icons/default/index.theme` with `Inherits=Adwaita`.
  3. `[Mouse]` block in `~/.config/lxqt/session.conf` + `XCURSOR_THEME`/
     `XCURSOR_SIZE` in `wm.service`'s `Environment=` *and* in
     `/etc/environment` (so PAM/dbus-activated processes inherit it,
     not just lxqt-session's direct children).
  4. `~/.Xresources` with `Xcursor.theme: Adwaita` + `Xcursor.size: 24`,
     merged into the X server via `xrdb -merge` in wm.service's
     `ExecStartPre` (requires `xorg-xrdb`). This is what fixes the
     core-cursor I-beam.
  `breeze-icons` is added for icons; depends only on `qt6-base`, not on
  Plasma.
- **Wallpaper**: pcmanfm-qt's desktop module is masked, so the X root
  window is what's visible behind apps. `/usr/local/bin/gen-wallpaper` does
  both: ImageMagick renders a 3840x2160 gradient PNG with the
  container's `hostname`, eth0 IP, and instance description (top-left),
  then `feh --bg-tile` paints the root. Wired via
  `~/.config/autostart/wallpaper.desktop` so it regenerates on every
  LXQt session start — picks up IP changes or renames automatically.
  Hardcoded font path (`/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf`)
  sidesteps fontconfig name-lookup flakiness. Description is read from
  `/etc/incus-vars` (sourced as shell), which `bin/new` writes for every
  container at provision time — see the launcher flow in the root
  `CLAUDE.md`.
- **pcmanfm-qt desktop is masked**. By default lxqt-session autostarts
  `pcmanfm-qt --desktop --profile=lxqt` (via
  `/etc/xdg/autostart/lxqt-desktop.desktop`), which renders broken
  Computer/Network/Trash shortcuts in a container. We drop a user
  override at `~/.config/autostart/lxqt-desktop.desktop` with
  `Hidden=true`. As belt-and-braces, `~/.config/pcmanfm-qt/lxqt/
  settings.conf` is seeded with `DesktopShortcuts=` (empty) in case a
  future change re-enables the module.
- **Brave** first-run noise is suppressed two ways:
  - `~/.config/brave-flags.conf` carries pre-profile flags:
    `--password-store=basic` (no kwallet), `--no-first-run`,
    `--no-default-browser-check`, `--force-dark-mode`,
    `--enable-features=WebUIDarkMode`.
  - `/etc/brave/policies/managed/dev.json` carries Chromium + Brave
    managed policies: kills sign-in, Sync, Rewards, Wallet, VPN, Leo
    (AI Chat), Talk, News, Tor, IPFS, P3A, stats ping, safe-browsing,
    metrics, search suggestions, password manager, default-browser
    prompt, promotional tabs. Inspect live values at `brave://policy`.
  - Split rationale: flags handle pre-profile/renderer behavior that
    has no policy equivalent (first-run sentinel, dark UA); policies
    handle in-profile features that have no flag equivalent.
- **Terminal is `alacritty`** (GPU-accelerated, ~5 MB, no toolkit deps).
  Config at `~/.config/alacritty/alacritty.toml` sets a dark palette
  (Atom-One-Dark-ish) + Monospace 10pt. `tmux` is installed for
  tabs/splits (alacritty itself has neither). qterminal was removed —
  it added little over alacritty and pulled qtermwidget deps.

## Trust model

Same as headless `dev` (shared uid 1000 + bind mounts = trusted-tool
isolation, not hostile-code sandbox). See `../dev/CLAUDE.md`. The GUI
layer adds Brave as a *renderer-process* attack surface, mitigated by
the managed policy file (no sync, no extensions store, no AI chat).
