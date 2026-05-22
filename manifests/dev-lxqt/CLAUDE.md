# dev-lxqt container specifics

Variant of `dev` that swaps the openbox+tint2+manual-theme stack for LXQt
(which still uses openbox underneath, but ships a coherent default
panel + session manager + theme system). Notes future-you will need.

- **Display stack** is two systemd services owned by uid 1000:
  `kasmvnc.service` (KasmVNC's combined X+VNC+web on `:8443`,
  passwordless via `-SecurityTypes None -disableBasicAuth`) and
  `wm.service` running `dbus-launch --exit-with-session
  /usr/bin/startlxqt`. `startlxqt` spawns `lxqt-session`, which in turn
  starts openbox + lxqt-panel + lxqt-notificationd + pcmanfm-qt.
- **dbus session bus** is required by lxqt-session (config writers,
  notificationd, panel). `dbus-launch --exit-with-session` provides one
  scoped to the lxqt-session lifetime; no separate user systemd unit.
- **XDG_RUNTIME_DIR** is pre-created by `ExecStartPre` (LXQt and Qt6 sulk
  if it's missing).
- **Resolution / KasmVNC install / IME mode / NVIDIA / CachyOS repos**
  are identical to the `dev` manifest — see `manifests/dev/CLAUDE.md`
  for the deep notes. Only the desktop layer differs.
- **Theming**: just `~/.config/lxqt/lxqt.conf` with `theme=Frost`
  (dark default shipped by `lxqt-themes`) + `icon_theme=breeze-dark`
  + `style=Fusion`. `QT_QPA_PLATFORMTHEME=lxqt` is exported by
  `wm.service` and by `session.conf`'s `[Environment]` block so Qt
  reads lxqt-qtplugin. No manual GTK config, no `kdeglobals`, no
  Konsole profile, no tint2 rc, no openbox rc.xml patching.
  `lxqt-config-appearance` lets you tweak from the GUI.
- **App menu**: lxqt-panel's main menu is XDG-driven. Brave (`brave-bin`)
  and qterminal install `.desktop` files into `/usr/share/applications/`
  and appear automatically; no manual menu wiring.
- **Panel layout is load-bearing**: lxqt-panel writes an almost-empty
  `panel.conf` on first launch (no `[panel1]` section, no `plugins=`),
  which renders as a near-blank bar with just a desktop switcher. We
  seed `~/.config/lxqt/panel.conf` with an explicit `[panel1]` +
  `plugins=mainmenu, quicklaunch, taskbar, spacer, statusnotifier, tray,
  worldclock, showdesktop`. lxqt-panel preserves these on first run
  (re-saves the file but keeps the keys). Each plugin needs its own
  `[<name>]` section with `type=<name>` for lxqt-panel to instantiate
  it.
- **X cursor theme is required**, otherwise raw X falls back to a giant
  bitmap cursor while Qt apps draw their own smaller one — two
  different cursors on the same screen. Fix is three-pronged:
  `xcursor-themes` package (ships `Adwaita`, ~3 MiB, no KDE deps);
  `~/.icons/default/index.theme` with `Inherits=Adwaita`;
  `[Mouse]` block in `~/.config/lxqt/session.conf` and
  `XCURSOR_THEME=Adwaita` + `XCURSOR_SIZE=24` in `wm.service`'s
  `Environment=`. `breeze-icons` is added for icons; depends only on
  `qt6-base`, not on Plasma.
- **pcmanfm-qt desktop is masked**. By default lxqt-session autostarts
  `pcmanfm-qt --desktop --profile=lxqt` (via
  `/etc/xdg/autostart/lxqt-desktop.desktop`), which renders broken
  Computer/Network/Trash shortcuts in a container. We drop a user
  override at `~/.config/autostart/lxqt-desktop.desktop` with
  `Hidden=true`. As belt-and-braces, `~/.config/pcmanfm-qt/lxqt/
  settings.conf` is seeded with `DesktopShortcuts=` (empty) in case a
  future change re-enables the module.
- **Brave config** (`brave-flags.conf` + managed policy JSON) is
  unchanged from `dev`.
- **No Konsole**: replaced with `qterminal` (LXQt's native terminal).
  No per-profile color scheme file needed — qterminal respects the
  active Qt palette.
- **Default shell** (zsh + oh-my-zsh + two-line prompt) is unchanged.

## Trust model

Same as `dev`: trusted-tool isolation (shared uid 1000 + bind mounts),
not a hostile-code sandbox. See `manifests/dev/CLAUDE.md` for the full
treatment.
