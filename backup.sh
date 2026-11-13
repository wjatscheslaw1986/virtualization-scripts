#!/bin/sh
set -eu

# Check if running as root
if [ "$(id -u)" = "0" ]; then
    echo "ERROR: This script must NOT be run as root" >&2
    exit 1
fi

usage() {
  echo "Usage: $0 <source_image> <destination_image>" >&2
  exit 1
}

[ $# -ge 1 ] || usage

src="${1}"
dst="${2:-${src%%.*}-$(date +%F).qcow2}"

[ -f "$src" ] || { echo "Error: source image '$src' not found" >&2; exit 1; }

qemu-img convert -O qcow2 "$src" "$dst" || {
  echo "Error: qemu-img conversion failed" >&2
  exit 1
}

chmod a-w "$dst"
echo "Successfully created backup '$dst' for '$src'. If you have created another disposable vm, then don't forget to make its' network identity unique: \n
    hostnamectl set-hostname <new_host_name> \n
    rm /etc/machine-id && systemd-machine-id-setup \n
    rm /etc/ssh/ssh_host_* && dpkg-reconfigure openssh-server"
