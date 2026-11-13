#!/bin/sh
set -eu

if [ "$(id -u)" = 0 ]; then
  echo "Please, don't run this script as root" >&2
  exit 1
fi

readonly SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
readonly QEMU=qemu-system-x86_64
readonly LAST_INDEX=5
readonly TAP_IF=${5:-tap0}

usage() {
    cat >&2 <<EOF
Usage: $(basename -- "$0") <disk-image> [scenario] [ram] [mac-address]

Runs a VM in QEMU with KVM acceleration.

Arguments:
  disk-image   Path to the qcow2 disk image to boot (required).
  scenario     Run scenario, an integer from 1 to ${LAST_INDEX} (default: 1):
                 1  Normal launch
                    Opens a graphical window with the VM console.
                 2  No-graphics launch
                    Runs in the foreground using the terminal
                    (-nographic). The VM console is attached to this
                    terminal; exit with Ctrl-a x. You must enable the serial
                    port first before using this mode:
                    sudo systemctl enable --now serial-getty@ttyS0.service
                    Optionally, send kernel/boot messages to serial too, by
                    setting the key in VM's /etc/default/grub to
                    GRUB_CMDLINE_LINUX_DEFAULT="quiet console=tty0 console=ttyS0,115200"
                    and executing: sudo update-grub
                 3  Daemon launch with bridged networking
                    Starts the VM in the background (-display none
                    -daemonize) attached to the tap interface "${TAP_IF}",
                    using the mandatory mac-address argument.
                    The tap must already exist and be attached to a bridge;
                    create it beforehand with your tap-creation script, run
                    as root:
                      create_user_tap.sh <bridge> ${TAP_IF} <user>
                    The guest then gets an address on the bridge network
                    (e.g. via DHCP). Connect with:
                    ssh <user>@<guest-ip>
                 4  Graphical launch with bridged networking
                    Same as scenario 3, but opens a graphical window with
                    the VM console instead of running in the background.
                    Uses the same mandatory mac-address argument and the
                    same pre-created tap interface "${TAP_IF}".
  ram          Amount of RAM in whole gigabytes (default: 2).
  mac-address  MAC address for the VM's network interface, e.g.
               52:54:00:00:00:01. Required for scenarios 3 and 4, ignored
               otherwise.

Examples:
  $(basename -- "$0") my-image.qcow2
  $(basename -- "$0") my-image.qcow2 3 4 52:54:00:00:00:01
  $(basename -- "$0") my-image.qcow2 4 4 52:54:00:00:00:01 tap1
  $(basename -- "$0") my-image.qcow2 2 4
EOF
    exit 1
}

die() {
    echo "Error: $1" >&2
    exit 1
}

[ "$#" -ge 1 ] && [ "$#" -le 5 ] || usage

DISK=$1
OPTION=${2:-1}
RAM=${3:-2}
MAC=${4:-}

case ${OPTION} in
    ''|*[!0-9]*) die "'${OPTION}' is not a valid integer." ;;
esac

if [ "${OPTION}" -lt 1 ] || [ "${OPTION}" -gt "${LAST_INDEX}" ]; then
    echo "Error: scenario must be between 1 and ${LAST_INDEX}, both inclusive." >&2
    usage
fi

case ${RAM} in
    ''|*[!0-9]*) die "'${RAM}' is not a valid amount of RAM (expected whole gigabytes)." ;;
esac
[ "${RAM}" -ge 1 ] || die "RAM must be at least 1 GB."

if [ ! -f "${DISK}" ]; then
    die "disk image '${DISK}' not found."
fi

command -v "${QEMU}" >/dev/null 2>&1 || die "${QEMU} is not installed or not in PATH."

VM_NAME=$(basename -- "${DISK}")
VM_NAME=${VM_NAME%%.*}
[ -n "${VM_NAME}" ] || die "cannot derive a VM name from '${DISK}'."

readonly MEM="${RAM}G"
readonly SMP=2
readonly PIDFILE="${SCRIPT_DIR}/${VM_NAME}.pid"
readonly MONITOR="${SCRIPT_DIR}/${VM_NAME}.sock"

launch() {
    "${QEMU}" -enable-kvm -cpu host -smp "${SMP}" -m "${MEM}" \
              -pidfile "${PIDFILE}" -monitor unix:"${MONITOR}",server,nowait \
              -drive file="${DISK}",if=virtio,format=qcow2 "$@"
}

clipboard_args() {
    echo -chardev qemu-vdagent,id=vdagent,clipboard=on \
         -device virtio-serial-pci \
         -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
}

check_bridged() {
    [ -n "${MAC}" ] || die "scenario ${OPTION} requires a MAC address; pass it as the fourth argument, e.g. $(basename -- "$0") ${DISK} ${OPTION} ${RAM} 52:54:00:00:00:01."
    case ${MAC} in
        [0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]:[0-9A-Fa-f][0-9A-Fa-f]) ;;
        *) die "'${MAC}' is not a valid MAC address (expected aa:bb:cc:dd:ee:ff)." ;;
    esac
    if ! [ -e "/sys/class/net/${TAP_IF}" ]; then
        die "tap interface '${TAP_IF}' does not exist; create it first (as root) with your tap-creation script, e.g. $(basename -- "$0")'s companion: create_user_tap.sh <bridge> ${TAP_IF} <user>."
    fi
}

bridged_netdev_args() {
    echo -netdev tap,id=net0,ifname=${TAP_IF},script=no \
         -device virtio-net-pci,netdev=net0,mac=${MAC}
}

case ${OPTION} in
    1)  launch ;;
    2)  launch -nographic ;;
    3)  check_bridged
        launch $(bridged_netdev_args) -display none -daemonize
        echo "VM '${VM_NAME}' started in background on tap '${TAP_IF}' with MAC ${MAC}. SSH: ssh <user>@<guest-ip> (pid file: ${PIDFILE}, monitor: ${MONITOR})"
        ;;
    4)  check_bridged
        launch $(bridged_netdev_args)
        ;;
    5)  check_bridged
        launch $(bridged_netdev_args) -usb -device usb-host,id=DCP7030,vendorid=0x04f9,productid=0x01ea -nographic ;;
    *)  die "invalid scenario '${OPTION}'." ;;
esac
