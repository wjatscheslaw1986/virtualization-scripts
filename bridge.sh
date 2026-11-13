#!/bin/sh

set -eu

PROGNAME=${0##*/}
BRIDGE_INTERFACE=${1:-br0}
BRIDGE_NAME=${2:-homelab-bridge}
BRIDGE_IPV4=${3:-"192.168.2.1/24"}

die() {
    printf '%s: error: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    die "must be run as root (try: sudo $0 $*)"
fi

#Manual address assignment to the interface must be redundant, since you may
#simply restart kea (systemctl restart kea-dhcp4-server.service) after the 
#bridge and its' slaves (the tap interfaces) are created.
tee /usr/local/sbin/"${BRIDGE_NAME}.sh" >/dev/null <<EOF
#!/bin/sh
set -eu
ip link add ${BRIDGE_INTERFACE} type bridge 2>/dev/null || true
ip addr add ${BRIDGE_IPV4} dev ${BRIDGE_INTERFACE} 2>/dev/null || true
ip link set ${BRIDGE_INTERFACE} up
EOF

chmod u+x /usr/local/sbin/"${BRIDGE_NAME}.sh"

tee /etc/systemd/system/"${BRIDGE_NAME}.service" >/dev/null <<EOF
[Unit]
Description=QEMU homelab bridge (${BRIDGE_INTERFACE})
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/${BRIDGE_NAME}.sh

[Install]
WantedBy=multi-user.target
EOF

systemctl enable --now "${BRIDGE_NAME}.service"

