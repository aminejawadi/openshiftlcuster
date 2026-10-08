#!/usr/bin/env bash
# Runs inside the helper VM (as root) during "vagrant up".
# - installs Ansible and the one collection the playbooks need
# - adds the fixed helper address (<VMnet8 subnet>.10) next to the DHCP address
#   Vagrant uses, so DNS and the ISO web server are always at a known IP.
set -euo pipefail

HELPER_OCTET="${HELPER_OCTET:-10}"

echo "==> Installing Ansible"
dnf -y -q install ansible-core
ansible-galaxy collection install ansible.posix -p /usr/share/ansible/collections >/dev/null

echo "==> Adding the fixed helper address"
dev="$(ip -4 route show default | awk '{print $5; exit}')"
cidr="$(ip -4 -o addr show dev "$dev" scope global | awk '{print $4; exit}')"
subnet="$(echo "${cidr%/*}" | cut -d. -f1-3)"
prefix="${cidr#*/}"
helper_ip="${subnet}.${HELPER_OCTET}"

if [ "$prefix" != "24" ]; then
  echo "VMnet8 uses /${prefix}; these playbooks expect a /24 network." >&2
  exit 1
fi

if ! ip -4 -o addr show dev "$dev" | grep -q " ${helper_ip}/"; then
  con="$(nmcli -g GENERAL.CONNECTION device show "$dev")"
  # Persist it in NetworkManager, then add it now without restarting the link
  # (restarting would drop Vagrant's SSH session).
  nmcli connection modify "$con" +ipv4.addresses "${helper_ip}/24"
  ip addr add "${helper_ip}/24" dev "$dev"
fi

echo "==> Helper reachable at ${helper_ip} (VMnet8 subnet ${subnet}.0/24)"
