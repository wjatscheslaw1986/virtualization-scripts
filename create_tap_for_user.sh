#!/bin/sh
#This script creates a slave TAP network interface for a given user.
#The given user must exist. The master interface (a bridge usually) must exist.

set -eu

if [ "$(id -u)" != 0 ]; then
  echo "Please, run this script as root" >&2
  exit 1
fi

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <bridge> <tap> <user>" >&2
  echo "Third argument must be the unprivileged user name." >&2
  exit 1
fi

BRIDGE_INTERFACE=$1
TAP_INTERFACE=$2
UNPRIVILEGED_USER=$3

if ! ip link show "$BRIDGE_INTERFACE" >/dev/null 2>&1; then
  echo "Bridge $BRIDGE_INTERFACE does not exist" >&2
  exit 1
fi

if ! id -u "$UNPRIVILEGED_USER" >/dev/null 2>&1; then
  echo "User $UNPRIVILEGED_USER does not exist" >&2
  exit 1
fi

if ip link show "$TAP_INTERFACE" >/dev/null 2>&1; then
  echo "Tap $TAP_INTERFACE already exists, reusing it" >&2
else
  ip tuntap add "$TAP_INTERFACE" mode tap user "$UNPRIVILEGED_USER"
fi

ip link set "$TAP_INTERFACE" master "$BRIDGE_INTERFACE"
ip link set "$TAP_INTERFACE" up

systemctl restart kea-dhcp4-server

