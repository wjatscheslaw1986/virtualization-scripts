#!/usr/bin/env bash
#
# setup-bridge-nm.sh - create a persistent Linux bridge with NetworkManager,
# enslave the uplink (default-facing or given) ethernet into it, and migrate
# the address/routes to the bridge. Intended for QEMU bridged networking:
# the bridge acts as the host's LAN endpoint and VMs attach via
# `-netdev bridge,br=<bridge>` or a tap enslaved to the bridge.
#
#: Usage:
#:   setup-bridge-nm.sh [options] [bridge] [uplink]
#:
#: Arguments:
#:   bridge   Name of the bridge to create.
#:            Default: br0
#:   uplink   Ethernet interface to enslave into the bridge.
#:            Default: the interface of the first IPv4 default route,
#:            skipping tun/tap and Wi-Fi devices.
#:            The slave NM connection name is derived from these:
#:            "<bridge>-slave-<uplink>" (e.g. br0-slave-enp0s31f6);
#:            override with -s/--slave-name.
#:
#: Options:
#:   -s, --slave-name NAME  NM connection name for the enslaved uplink
#:                          (default: <bridge>-slave-<uplink>)
#:   -n, --dry-run          Show what would be done, change nothing.
#:   -f, --force            Skip the interactive confirmation prompt.
#:   -q, --setup-qemu       Also add "<bridge>" to /etc/qemu/bridge.conf so
#:                          QEMU's bridge helper is allowed to use it.
#:   -h, --help             Show this help and exit.
#
# Behaviour:
#   - Idempotent: re-running with an existing matching bridge/uplink pair is
#     a no-op; a conflicting shape errors out with instructions.
#   - Persistent: the bridge survives reboots (NM connection profiles).
#   - Rollback: on failure, deactivates and deletes what was created and
#     re-activates the uplink's original connection.
#   - Addressing and routes migrate automatically when NM moves the port
#     into the bridge. Check VPN-pinned routes afterwards.
#
#: Examples:
#:   setup-bridge-nm.sh                          # br0, default-route ethernet
#:   setup-bridge-nm.sh br1 enp0s31f6             # explicit bridge + uplink
#:   setup-bridge-nm.sh -s lan0-port br0 enp0s31f6
#:   setup-bridge-nm.sh -n br0 enp0s31f6         # dry-run
#:   setup-bridge-nm.sh -qf br0 enp0s31f6        # non-interactive + qemu setup
#:
#: After running, start QEMU with:
#:   qemu-system-x86_64 ... \
#:     -netdev bridge,id=n0,br=br0 -device virtio-net-pci,netdev=n0

set -Eeuo pipefail

BRIDGE_NAME="br0"
UPLINK_IFACE=""
SLAVE_NAME=""

DRY_RUN=0
FORCE=0
SETUP_QEMU=0

# --- Helpers -------------------------------------------------------------------
usage() { grep -E '^#:' "$0" | sed 's/^#://'; }
log()    { printf '[setup-bridge] %s\n' "$*" >&2; }
die()    { log "ERROR: $*"; exit 1; }
need()   { command -v "$1" &>/dev/null || die "required command not found: $1"; }
run() {
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "DRY-RUN: $*"
    else
        log "$ $*"
        "$@"
    fi
}

# --- Parse options and positional arguments -------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)    DRY_RUN=1; shift ;;
        -f|--force)      FORCE=1; shift ;;
        -q|--setup-qemu) SETUP_QEMU=1; shift ;;
        -s|--slave-name)
            [[ $# -ge 2 ]] || die "--slave-name requires a value"
            SLAVE_NAME="$2"; shift 2 ;;
        --slave-name=*)  SLAVE_NAME="${1#*=}"; shift ;;
        -h|--help)       usage; exit 0 ;;
        --)              shift; POSITIONAL+=("$@"); break ;;
        -*)              die "unknown option: $1 (see --help)" ;;
        *)               POSITIONAL+=("$1"); shift ;;
    esac
done
set -- "${POSITIONAL[@]:-}"

[[ $# -gt 2 ]] && die "too many arguments: expected at most [bridge] [uplink] (see --help)"
[[ $# -ge 1 ]] && BRIDGE_NAME="$1"
[[ $# -ge 2 ]] && UPLINK_IFACE="$2"

# --- Preflight checks ------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || die "must be run as root (try: sudo $0 $*)"
need nmcli
need ip

if [[ ${DRY_RUN} -eq 0 ]] && ! nmcli general status &>/dev/null; then
    die "NetworkManager is not running"
fi

# Validate the bridge name early so the slave name derivation is safe.
[[ ${BRIDGE_NAME} =~ ^[a-zA-Z0-9._-]{1,15}$ ]] || die "invalid bridge name: '${BRIDGE_NAME}'"

# Resolve uplink: first IPv4 default-route interface, skipping tun/tap and Wi-Fi.
if [[ -z ${UPLINK_IFACE} ]]; then
    UPLINK_IFACE="$(ip -4 route show default \
        | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' \
        | while read -r dev; do
            ip -o link show dev "$dev" | grep -qw POINTOPOINT && continue
            [[ -e /sys/class/net/"$dev"/phy80211 ]] && continue
            echo "$dev"
          done | head -n1)"
    [[ -n ${UPLINK_IFACE} ]] || die "could not determine a bridgable default-route interface; pass it as argument 2"
fi

ip link show dev "${UPLINK_IFACE}" &>/dev/null \
    || die "interface '${UPLINK_IFACE}' does not exist"
ip -o link show dev "${UPLINK_IFACE}" | grep -qw POINTOPOINT \
    && die "refusing to bridge '${UPLINK_IFACE}': tun/tap (layer-3) interfaces cannot be bridged"
[[ -e /sys/class/net/"${UPLINK_IFACE}"/phy80211 ]] \
    && die "refusing to bridge '${UPLINK_IFACE}': Wi-Fi in station mode cannot be bridged"
ip -o link show dev "${UPLINK_IFACE}" | grep -qw LOOPBACK \
    && die "refusing to bridge loopback"

# Derived slave connection name: <bridge>-slave-<uplink>
SLAVE_NAME="${SLAVE_NAME:-${BRIDGE_NAME}-slave-${UPLINK_IFACE}}"
[[ ${SLAVE_NAME} =~ ^[a-zA-Z0-9._-]+$ ]] || die "invalid slave name: '${SLAVE_NAME}'"

# Idempotency checks.
if nmcli connection show "${BRIDGE_NAME}" &>/dev/null; then
    if [[ $(nmcli -g connection.master connection show id "${BRIDGE_NAME}" 2>/dev/null) == "" ]] \
       && nmcli connection show "${SLAVE_NAME}" &>/dev/null; then
        log "bridge '${BRIDGE_NAME}' with slave '${SLAVE_NAME}' already exists - nothing to do"
        exit 0
    fi
    die "NM connection '${BRIDGE_NAME}' already exists with a different shape; inspect it (nmcli connection show '${BRIDGE_NAME}') or delete it first"
fi
nmcli connection show "${SLAVE_NAME}" &>/dev/null \
    && die "NM connection '${SLAVE_NAME}' already exists; delete it first or use -s to pick another name"
if ip link show dev "${BRIDGE_NAME}" &>/dev/null; then
    die "interface '${BRIDGE_NAME}' already exists but is not managed as the expected NM connection; resolve manually"
fi

current_master="$(nmcli -g GENERAL.CONNECTION device show "${UPLINK_IFACE}" 2>/dev/null || true)"

# --- Confirm ---------------------------------------------------------------------
if [[ ${FORCE} -ne 1 ]]; then
    log "About to create bridge '${BRIDGE_NAME}' and enslave '${UPLINK_IFACE}'."
    log "Address/routes on '${UPLINK_IFACE}' migrate to the bridge; expect a brief"
    log "connectivity gap. If connected over '${UPLINK_IFACE}' (SSH), run inside tmux/screen."
    read -r -p "Continue? [y/N] " reply
    [[ ${reply,,} == y ]] || die "aborted"
fi

# --- Rollback ---------------------------------------------------------------------
rollback() {
    log "step failed; rolling back"
    nmcli connection down "${BRIDGE_NAME}"   &>/dev/null || true
    nmcli connection delete "${SLAVE_NAME}"  &>/dev/null || true
    nmcli connection delete "${BRIDGE_NAME}"  &>/dev/null || true
    [[ -n ${current_master} && ${current_master} != "--" && ${current_master} != "unmanaged" ]] \
        && nmcli connection up id "${current_master}" &>/dev/null || true
}
if [[ ${DRY_RUN} -eq 0 ]]; then
    trap 'rollback; die "failed (rolled back)"' ERR
fi

# --- Create bridge, enslave uplink, activate ---------------------------------------
tee /etc/NetworkManager/conf.d/99-vm-"${BRIDGE_NAME}"-unmanage.conf >/dev/null <<EOF
[keyfile]
unmanaged-devices=interface-name:${BRIDGE_NAME};interface-name:tap*
EOF

systemctl reload NetworkManager &>/dev/null || true

run nmcli connection add type bridge ifname "${BRIDGE_NAME}" con-name "${BRIDGE_NAME}" \
    ipv4.method auto ipv6.method auto \
    bridge.stp no

run nmcli connection add type ethernet ifname "${UPLINK_IFACE}" con-name "${SLAVE_NAME}" \
    master "${BRIDGE_NAME}" slave-type bridge \
    connection.autoconnect yes

log "ToDo: now you need to add at least one slave TAP interfece to the bridge to make it up: ./create_tap_for_user.sh ${BRIDGE_NAME} <tap> <user>"
log "ToDo: restart kea dhcp4 server (systemctl restart kea-dhcp4-server.service) after adding the TAP interface. Or set it up by running ./setup_kea.sh ${BRIDGE_NAME}"

[[ ${DRY_RUN} -eq 0 ]] && trap - ERR

# --- Optional QEMU helper config ---------------------------------------------------
if [[ ${SETUP_QEMU} -eq 1 ]]; then
    QEMU_BRIDGE_CONF="/etc/qemu/bridge.conf"
    if [[ ${DRY_RUN} -eq 1 ]]; then
        log "DRY-RUN: echo 'allow ${BRIDGE_NAME}' >> ${QEMU_BRIDGE_CONF}"
    else
        [[ -f ${QEMU_BRIDGE_CONF} ]] || die "cannot configure QEMU: ${QEMU_BRIDGE_CONF} not found (install the qemu bridge helper or add 'allow ${BRIDGE_NAME}' manually)"
        grep -qx "allow ${BRIDGE_NAME}" "${QEMU_BRIDGE_CONF}" \
            || echo "allow ${BRIDGE_NAME}" >> "${QEMU_BRIDGE_CONF}"
    fi
fi

# --- Report -------------------------------------------------------------------------
log "done. bridge=${BRIDGE_NAME} uplink=${UPLINK_IFACE} slave=${SLAVE_NAME}"
if [[ ${DRY_RUN} -eq 0 ]]; then
    ip -br addr show dev "${BRIDGE_NAME}" || true
    ip route show default || true
    log "QEMU usage: -netdev bridge,id=n0,br=${BRIDGE_NAME} -device virtio-net-pci,netdev=n0"
    log "How to UNDO: nmcli connection delete ${SLAVE_NAME} ${BRIDGE_NAME} && nmcli connection up id '${current_master}'"
fi
