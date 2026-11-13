#!/bin/sh

set -eu

if [ "$(id -u)" != 0 ]; then
  echo "Please, run this script as root" >&2
  exit 1
fi

BRIDGE="${1:-br0}"

tee /etc/kea/kea-dhcp4.conf >/dev/null <<EOF
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "${BRIDGE}" ]
    },
    "valid-lifetime": 3600,
    "subnet4": [
      {
        "id": 1,
        "subnet": "192.168.2.0/24",
        "pools": [
          { "pool": "192.168.2.100 - 192.168.2.200" }
        ],
        "option-data": [
          { "name": "routers", "data": "192.168.2.1" },
          { "name": "domain-name-servers", "data": "77.88.8.88" }
        ],
        "reservations": [
          {
            "hw-address": "52:54:00:00:00:01",
            "ip-address": "192.168.2.11",
            "hostname": "debian-lab-1"
          },
          {
            "hw-address": "52:54:00:00:00:02",
            "ip-address": "192.168.2.12",
            "hostname": "debian-lab-2"
          }
        ]
      }
    ]
  }
}
EOF

kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
systemctl restart kea-dhcp4-server
#journalctl -u kea-dhcp4-server -f       # watch the leases happen

