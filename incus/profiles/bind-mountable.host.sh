#!/usr/bin/env bash
# Host prep for the `bind-mountable` profile.
#
# The profile sets `raw.idmap uid 1000 1000` so host uid/gid 1000 maps onto
# the container's uid/gid 1000. Incus requires the host's `root` entry in
# /etc/subuid and /etc/subgid to include 1000 in its allowed range.
#
# Idempotent. Run by bin/new whenever a manifest includes this profile.

set -euo pipefail

need=0
grep -qx 'root:1000:1' /etc/subuid 2>/dev/null || need=1
grep -qx 'root:1000:1' /etc/subgid 2>/dev/null || need=1

if [[ "${need}" -eq 1 ]]; then
  log "[bind-mountable] Adding root:1000:1 to /etc/subuid and /etc/subgid (requires sudo)"
  sudo sh -c '
    grep -qx root:1000:1 /etc/subuid || echo root:1000:1 >>/etc/subuid
    grep -qx root:1000:1 /etc/subgid || echo root:1000:1 >>/etc/subgid
  '
fi
