#!/bin/sh

set -eu

if [ "$(id -u)" = 0 ]; then
  echo "Please, don't run this script as root" >&2
  exit 1
fi

#readonly SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VM_IMAGE_FILE="${1}"
OS_ISO_FILE="${2}"
VM_IMAGE_SIZE_GB="${3:-20}"
RAM_SIZE_GB="${4:-2}"
readonly SMP=2

if [ -z "${VM_IMAGE_FILE}" ]; then
    echo "VM image name isn't set, but required."
    exit 1
fi

if [ ! -f "${OS_ISO_FILE}" ]; then
    echo "OS image ${OS_ISO_FILE} not found, but required."
    exit 1
fi

qemu-img create -f qcow2 "${VM_IMAGE_FILE}" "${VM_IMAGE_SIZE_GB}"G
qemu-img info "${VM_IMAGE_FILE}"
#You may want to resize the image later:
#qemu-img resize "${VM_IMAGE_FILE}" 30G
#You may want to convert the image into the raw format:
#qemu-img convert -f qcow2 -O raw "${VM_IMAGE_FILE}" "${VM_IMAGE_FILE}".raw
qemu-system-x86_64 -enable-kvm -cpu host -smp "${SMP}" -m "${RAM_SIZE_GB}"G -drive file="${VM_IMAGE_FILE}",if=virtio,format=qcow2 -cdrom "${OS_ISO_FILE}" -boot d
