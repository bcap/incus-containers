# dev container specifics

Notes future-you will need when editing `base.sh`, `user.sh`, or
`container.sh` in this directory. `dev` is the headless base: CachyOS
repos + Arch toolchain + an unprivileged `user` (uid 1000) with zsh.
The GUI layer lives in [../dev-gui/](../dev-gui/) and reuses these two
scripts via relative paths in `SETUP_SCRIPTS`.

## Setup script split

- **`base.sh`** — runs first. Enables CachyOS repos (pinned to
  keyserver.ubuntu.com for `pacman-key --recv-keys` reliability), runs
  one explicit `pacman -Syu`, then installs the base toolchain +
  `nvidia-utils`. Ends with an `nvidia-smi -L` soft-check (warns rather
  than fails — non-GPU manifests can still reuse this script).
- **`user.sh`** — runs second. Creates `user` uid 1000 with passwordless
  wheel sudo, seeds zsh + oh-my-zsh + the custom two-line prompt.
  Depends on packages from `base.sh` (`zsh`, `sudo`, `curl`, `git`).
  No GUI-specific config here — `xdg-user-dirs` is disabled in
  `dev-gui/gui.sh` because nothing triggers `xdg-user-dirs-update` in
  a headless container.

Both scripts are self-contained — own `log()`, own root check, own
`pac_install()` in `base.sh`. They're run as separate `bash` processes,
so no state crosses script boundaries other than what's written to the
container's filesystem.

## Key choices

- **NVIDIA in base, not GUI.** Headless CUDA dev is a valid use of this
  manifest. The container still installs `nvidia-utils` and includes
  the `gpu-nvidia` profile by default. Strip the profile for non-GPU
  manifests; the `nvidia-smi` check at the end of `base.sh` just warns.
- **`nvidia.runtime: true` would be cleaner** than per-container
  `nvidia-utils`, but currently fails at mount-hook time on this host
  (Incus 7.0 + libnvidia-container 1.19).
- **CachyOS repos** are enabled here (not just in GUI) so v4-optimized
  builds + extra packages are available to headless containers too.
  Requires a host CPU with x86-64-v4 support (Zen 4+ / Sapphire Rapids+).
- **zsh + oh-my-zsh** for `user` only; root keeps the default shell.
  `.zshrc` is written verbatim; oh-my-zsh installer runs with
  `--keep-zshrc` so our config survives.

## Trust model

Shared uid 1000 + bind-mounted host dirs = **trusted-tool isolation**,
not hostile-code sandbox. A container escape lands as the host user.
Mitigates renderer-process compromise and accidental damage from a buggy
agent (scoped to the container FS). Does **not** defend against
kernel/LXC escapes or unscoped network egress on incusbr0. Harden by
swapping `raw.idmap` for `security.idmap.isolated: true`, dropping bind
mounts, and using `--ephemeral`.
