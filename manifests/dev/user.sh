#!/usr/bin/env bash
# User setup. Run as root inside the container:
#   bash /root/user.sh
#
# Creates:
#   - 'user' user (uid 1000, passwordless wheel)
#   - zsh + oh-my-zsh with a custom two-line prompt as the user's shell
#   - XDG user-dirs disabled (no Desktop/Documents/... auto-creation)
#
# Assumes base.sh has already installed zsh, sudo, curl, git.

set -euo pipefail

log() { printf '%s => %s\n' "$(date -Iseconds)" "$*" >&2; }

USER_UID=1000
USER_NAME="user"

if [[ "$(id -u)" -ne 0 ]]; then
  log "must run as root inside the container"
  exit 1
fi

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

install -d -m 0755 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.config"

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

log "user setup complete"
