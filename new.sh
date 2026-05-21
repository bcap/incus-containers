#!/usr/bin/env bash
# Launch a llm-agent container.
#
# Usage: ./launch.sh NAME
#
# Idempotent for the one-time bits (host subuid/subgid, profile load).
# Errors out if a container with NAME already exists.

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [--vnc[=CLIENT]] NAME
       $(basename "$0") -h | --help

Launch a new llm-agent Incus container named NAME.

What this script does:
  1. Ensures one-time host prep is in place:
     - Adds 'root:1000:1' to /etc/subuid and /etc/subgid (sudo) if missing.
       Required by the profile's 'raw.idmap uid 1000 1000', which maps the
       host user's uid/gid onto the container's uid/gid 1000.
  2. Creates the 'llm-agent', 'gpu-nvidia', and 'bind-mountable' Incus
     profiles if absent, then syncs each from incus/profiles/*.yaml on
     every run so the profiles track the YAML.
  3. Launches an Arch Linux container NAME using 'default' + the three
     profiles above. Errors out if NAME already exists.
  4. Pushes and runs setup.sh inside the container, which
     creates the 'agent' user (uid 1000, passwordless wheel) and installs
     the GUI stack (KasmVNC + openbox + tint2), Brave, nvidia-utils,
     and the systemd services that keep them running.
  5. Restarts the container and prints the incusbr0 IP, web-client URL,
     and a shell command.

Arguments:
  NAME            Container name (required).

Options:
  --vnc[=CLIENT]  After provisioning, launch a VNC viewer pointed at the
                  container. CLIENT defaults to 'vncviewer'.
  -h, --help      Show this help and exit.

Connect after launch:
  Open https://<ip>:8443/vnc.html in a browser (user: agent / pass: agentagent)
  vncviewer <ip>:8443
  incus exec NAME -- sudo -iu agent
EOF
}

NAME=""
VNC_CLIENT=""
LAUNCH_VNC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --vnc)
      LAUNCH_VNC=1
      VNC_CLIENT="vncviewer"
      ;;
    --vnc=*)
      LAUNCH_VNC=1
      VNC_CLIENT="${1#--vnc=}"
      [[ -n "${VNC_CLIENT}" ]] || { echo "--vnc=CLIENT requires a value" >&2; exit 1; }
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      [[ -z "${NAME}" ]] || { echo "Unexpected argument: $1" >&2; exit 1; }
      NAME="$1"
      ;;
  esac
  shift
done

if [[ -z "${NAME}" ]]; then
  usage >&2
  exit 1
fi

if [[ "${LAUNCH_VNC}" -eq 1 ]] && ! command -v "${VNC_CLIENT}" >/dev/null 2>&1; then
  echo "VNC client '${VNC_CLIENT}' not found in PATH" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="${SCRIPT_DIR}/incus/profiles"
SETUP_SH="${SCRIPT_DIR}/setup.sh"
PROFILES=(llm-agent gpu-nvidia bind-mountable)
USER_NAME="agent"

[[ -f "${SETUP_SH}" ]] || { echo "Missing: ${SETUP_SH}" >&2; exit 1; }
for p in "${PROFILES[@]}"; do
  [[ -f "${PROFILES_DIR}/${p}.yaml" ]] || { echo "Missing: ${PROFILES_DIR}/${p}.yaml" >&2; exit 1; }
done

if incus info "${NAME}" >/dev/null 2>&1; then
  echo "Container '${NAME}' already exists. Delete it first: incus delete ${NAME} --force" >&2
  exit 1
fi

# --- One-time host prep: subuid/subgid for raw.idmap uid 1000 1000 ---
need_subid=0
grep -qx 'root:1000:1' /etc/subuid 2>/dev/null || need_subid=1
grep -qx 'root:1000:1' /etc/subgid 2>/dev/null || need_subid=1
if [[ "${need_subid}" -eq 1 ]]; then
  echo "[host] Adding root:1000:1 to /etc/subuid and /etc/subgid (requires sudo)..."
  sudo sh -c '
    grep -qx root:1000:1 /etc/subuid || echo root:1000:1 >>/etc/subuid
    grep -qx root:1000:1 /etc/subgid || echo root:1000:1 >>/etc/subgid
  '
fi

# --- One-time profile load (refresh from YAML every run to keep in sync) ---
for p in "${PROFILES[@]}"; do
  if ! incus profile show "${p}" >/dev/null 2>&1; then
    echo "[host] Creating Incus profile '${p}'..."
    incus profile create "${p}"
  fi
  echo "[host] Syncing profile '${p}' from ${PROFILES_DIR}/${p}.yaml..."
  incus profile edit "${p}" < "${PROFILES_DIR}/${p}.yaml"
done

# --- Launch ---
echo "[host] Launching container '${NAME}'..."
PROFILE_ARGS=(-p default)
for p in "${PROFILES[@]}"; do PROFILE_ARGS+=(-p "${p}"); done
incus launch images:archlinux "${NAME}" "${PROFILE_ARGS[@]}"

# Wait for the container to be ready enough to exec into it.
echo "[host] Waiting for container to be ready..."
for _ in $(seq 1 30); do
  if incus exec "${NAME}" -- true >/dev/null 2>&1; then break; fi
  sleep 1
done

# Wait for network: DHCP lease on eth0 + DNS resolving.
# Without this, pacman -Sy fails with "Could not resolve host".
echo "[host] Waiting for container network..."
for _ in $(seq 1 60); do
  if incus exec "${NAME}" -- getent hosts archlinux.org >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
if ! incus exec "${NAME}" -- getent hosts archlinux.org >/dev/null 2>&1; then
  echo "[host] Container network not ready after 60s. Check 'incus exec ${NAME} -- ip a' and resolv.conf." >&2
  exit 1
fi

# --- Provision (setup script creates the 'agent' user itself) ---
echo "[${NAME}] Pushing and running setup script..."
incus file push "${SETUP_SH}" "${NAME}/root/setup.sh" --mode 0755
incus exec "${NAME}" -- bash /root/setup.sh

echo "[host] Restarting container..."
incus restart "${NAME}"

# Wait for eth0 to reacquire a DHCP lease after restart so we can print the IP.
echo "[host] Waiting for container IP..."
IP=""
for _ in $(seq 1 60); do
  IP="$(incus list "${NAME}" -c 4 --format csv 2>/dev/null | awk '{print $1}')"
  [[ -n "${IP}" ]] && break
  sleep 1
done

# Wait for KasmVNC to be reachable from the host on incusbr0.
KASM_PORT=8443
VNC_READY=0
if [[ -n "${IP}" ]]; then
  echo "[host] Waiting for KasmVNC on ${IP}:${KASM_PORT}..."
  for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/${IP}/${KASM_PORT}") 2>/dev/null; then
      exec 3<&- 3>&-
      VNC_READY=1
      break
    fi
    sleep 1
  done
fi

if [[ -z "${IP}" ]]; then
  echo
  echo "Container '${NAME}' is up but no IP yet. Re-check with: incus list ${NAME}" >&2
  exit 0
fi

VNC_STATUS="ready"
[[ "${VNC_READY}" -eq 0 ]] && VNC_STATUS="not responding yet — retry in a few seconds"

cat <<EOF

Container '${NAME}' is up.
  IP:     ${IP}
  Web:    https://${IP}:${KASM_PORT}/vnc.html  (${VNC_STATUS})
          user: ${USER_NAME}  pass: ${USER_NAME}${USER_NAME}
  VNC:    vncviewer ${IP}:${KASM_PORT}
  Shell:  incus exec ${NAME} -- sudo -iu ${USER_NAME}
EOF

if [[ "${LAUNCH_VNC}" -eq 1 ]]; then
  echo
  echo "[host] Launching ${VNC_CLIENT} ${IP}:${KASM_PORT}..."
  exec "${VNC_CLIENT}" "${IP}:${KASM_PORT}"
fi
