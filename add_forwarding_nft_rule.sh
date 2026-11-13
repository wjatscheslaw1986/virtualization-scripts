#!/bin/sh

set -eu

LC_ALL=C
export LC_ALL

PROGNAME=${0##*/}
ORIGINAL_ARGS=$*

BRIDGE_NAME=${1:-"br0"}
BRIDGE_SUBNET=${2:-"192.168.2.0/24"}
DRY_RUN=0
REMOVE=0
POSITIONAL=0

die() {
    printf '%s: error: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

log() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
}

usage() {
    cat <<EOF
Usage: $PROGNAME [OPTIONS] [BRIDGE_NAME] [SUBNET]

Enable NAT (masquerade) and firewall pass-through for traffic leaving a
Linux bridge network, using nftables. Safe to re-run: previously
installed rules for the bridge are replaced, not duplicated.

Arguments:
  BRIDGE_NAME  Bridge interface (default: br0)
  SUBNET       IPv4 subnet behind the bridge, CIDR (default: 192.168.2.0/24)

Options:
  -r, --remove   Remove rules previously installed by this script
  -n, --dry-run  Print actions instead of performing them
  -h, --help     Show this help

Behaviour:
  * Rules are installed into chain "forward" of table "inet filter" and
    chain "postrouting" of table "inet nat"; missing tables/chains are
    created. Rules carry a "brnat-<bridge>" comment so they can be
    identified and cleanly removed later.
  * Enables net.ipv4.ip_forward if not already set.
  * Rules are runtime-only and do not survive a reboot; add the rules
    printed by --dry-run to your persistent nftables configuration if
    needed.
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -r|--remove)
            REMOVE=1
            ;;
        -n|--dry-run)
            DRY_RUN=1
            ;;
        -*)
            usage >&2
            die "unknown option: $1"
            ;;
        *)
            POSITIONAL=$((POSITIONAL + 1))
            case $POSITIONAL in
                1) BRIDGE_NAME=$1 ;;
                2) BRIDGE_SUBNET=$1 ;;
                *) die "too many arguments: $1 (see --help)" ;;
            esac
            ;;
    esac
    shift
done

if [ "$(id -u)" -ne 0 ]; then
    die "must be run as root (try: sudo $0 $ORIGINAL_ARGS)"
fi

command -v nft >/dev/null 2>&1 || die "nft not found in PATH"
command -v awk >/dev/null 2>&1 || die "awk not found in PATH"
nft list tables >/dev/null 2>&1 || die "nftables is not usable on this system"

case $BRIDGE_NAME in
    ''|*[!A-Za-z0-9._-]*)
        die "invalid bridge name: $BRIDGE_NAME"
        ;;
esac
[ "${#BRIDGE_NAME}" -le 15 ] || die "interface name too long (max 15 chars)"

TAG="brnat-${BRIDGE_NAME}"

table_exists() {
    nft list table "$1" "$2" >/dev/null 2>&1
}

chain_exists() {
    nft list chain "$1" "$2" "$3" >/dev/null 2>&1
}

rule_installed() {
    nft list chain "$1" "$2" "$3" 2>/dev/null | grep -Fq "\"$TAG\""
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "$*"
        return 0
    fi
    if ! "$@"; then
        die "command failed: $*"
    fi
}

purge_rules() {
    _family=$1
    _table=$2
    _chain=$3
    chain_exists "$_family" "$_table" "$_chain" || return 0
    _cmds=$(nft -a list chain "$_family" "$_table" "$_chain" | awk \
        -v tag="comment \"${TAG}\"" \
        -v family="$_family" \
        -v table="$_table" \
        -v chain="$_chain" '
        index($0, tag) > 0 {
            handle = ""
            for (i = 1; i < NF; i++) {
                if ($i == "#" && $(i + 1) == "handle") {
                    handle = $(i + 2)
                    break
                }
            }
            if (handle != "") {
                printf "delete rule %s %s %s %s\n", family, table, chain, handle
            }
        }')
    [ -n "$_cmds" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s\n' "$_cmds"
    else
        printf '%s\n' "$_cmds" | nft -f - || die "failed to remove stale rules"
    fi
}

is_ipv4_cidr() (
    case $1 in
        */*/*|*[!0-9./]*) return 1 ;;
    esac
    IFS=/ read -r _addr _prefix <<EOF
$1
EOF
    case $_prefix in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_prefix" -le 32 ] || return 1
    IFS=.
    set -- $_addr
    [ $# -eq 4 ] || return 1
    for _octet in "$@"; do
        case $_octet in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$_octet" -le 255 ] || return 1
    done
    return 0
)

if [ "$REMOVE" -eq 1 ]; then
    purge_rules inet filter forward
    purge_rules inet nat postrouting
    if [ "$DRY_RUN" -eq 1 ]; then
        log "[dry-run] would remove bridge NAT rules for '$BRIDGE_NAME'"
    else
        log "removed bridge NAT rules for '$BRIDGE_NAME'"
    fi
    exit 0
fi

is_ipv4_cidr "$BRIDGE_SUBNET" || die "invalid IPv4 subnet (expected CIDR like 192.168.2.0/24): $BRIDGE_SUBNET"

[ -d "/sys/class/net/$BRIDGE_NAME" ] || die "interface '$BRIDGE_NAME' does not exist"
if [ ! -d "/sys/class/net/$BRIDGE_NAME/bridge" ]; then
    log "warning: '$BRIDGE_NAME' exists but is not a bridge; applying rules anyway"
fi

if [ ! -r /proc/sys/net/ipv4/ip_forward ]; then
    die "cannot read /proc/sys/net/ipv4/ip_forward"
fi
ip_fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null) || ip_fwd=0
if [ "$ip_fwd" != "1" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '%s: [dry-run] sysctl -w net.ipv4.ip_forward=1\n' "$PROGNAME" >&2
    else
        printf '1\n' > /proc/sys/net/ipv4/ip_forward || die "failed to enable net.ipv4.ip_forward"
    fi
fi

table_exists inet filter || run nft add table inet filter
chain_exists inet filter forward || \
    run nft add chain inet filter forward '{ type filter hook forward priority 0; policy accept; }'
table_exists inet nat || run nft add table inet nat
chain_exists inet nat postrouting || \
    run nft add chain inet nat postrouting '{ type nat hook postrouting priority 100; }'

purge_rules inet filter forward
purge_rules inet nat postrouting

run nft insert rule inet filter forward \
    iifname "\"$BRIDGE_NAME\"" ip saddr "$BRIDGE_SUBNET" accept comment "\"$TAG\""
run nft insert rule inet filter forward \
    oifname "\"$BRIDGE_NAME\"" ip daddr "$BRIDGE_SUBNET" ct state established,related accept comment "\"$TAG\""
run nft add rule inet nat postrouting \
    ip saddr "$BRIDGE_SUBNET" oifname != "\"$BRIDGE_NAME\"" masquerade comment "\"$TAG\""
run nft insert rule inet filter input iifname "\"$BRIDGE_NAME\"" \
    ip saddr "$BRIDGE_SUBNET" udp dport 53 accept comment "\"$TAG\""

if [ "$DRY_RUN" -eq 0 ]; then
    rule_installed inet filter forward || {
        purge_rules inet filter forward
        purge_rules inet nat postrouting
        die "verification failed: forward rules not found after apply; rolled back"
    }
    rule_installed inet nat postrouting || {
        purge_rules inet filter forward
        purge_rules inet nat postrouting
        die "verification failed: masquerade rule not found after apply; rolled back"
    }
    log "NAT enabled for '$BRIDGE_NAME' (${BRIDGE_SUBNET}); rules tagged '$TAG'"
    log "note: rules are runtime-only and will not survive a reboot"
else
    log "[dry-run] no changes were made"
fi
