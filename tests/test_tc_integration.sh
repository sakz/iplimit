#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export IPLIMIT_LIBRARY_ONLY=1
export IPLIMIT_CONFIG_FILE=/tmp/iplimit-integration.conf
export IPLIMIT_STATE_DIR=/tmp/iplimit-integration-state

# shellcheck disable=SC1091
source "$ROOT_DIR/iplimit"

TEST_INTERFACE="wan-iptest"
TEST_PEER="peer-iptest"
TEST_NAMESPACE="iplimit-test"
IFB_NAME="ifb-iptest"
INTERFACE="$TEST_INTERFACE"
RATE_MBIT="20"

cleanup_test() {
    set +e
    cleanup_network "$TEST_INTERFACE"
    ip netns delete "$TEST_NAMESPACE" 2>/dev/null
    ip link delete "$TEST_INTERFACE" 2>/dev/null
    rm -rf "$IPLIMIT_STATE_DIR" "$IPLIMIT_CONFIG_FILE"
}
trap cleanup_test EXIT

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'ok - %s\n' "$1"
}

class_packets() {
    local device=$1
    local classid=$2
    tc -s class show dev "$device" classid "$classid" | awk '/ Sent / { print $4; exit }'
}

[[ $(id -u) -eq 0 ]] || fail "integration test must run as root"

FOREIGN_IFB="ifb-foreign"

legacy_device="legacy-test"
ip link add "$legacy_device" type dummy
ip link set "$legacy_device" up
tc qdisc add dev "$legacy_device" clsact
tc filter add dev "$legacy_device" ingress pref 49152 protocol all matchall action pass
INTERFACE="$legacy_device"
IFB_NAME="$FOREIGN_IFB"
setup_network "$legacy_device"
tc filter show dev "$legacy_device" ingress pref 49152 | grep -q 'matchall' \
    || fail "foreign legacy-priority filter was deleted"
cleanup_network "$legacy_device"
tc filter show dev "$legacy_device" ingress pref 49152 | grep -q 'matchall' \
    || fail "cleanup deleted foreign legacy-priority filter"
tc filter del dev "$legacy_device" ingress pref 49152 protocol all
tc qdisc del dev "$legacy_device" clsact
ip link delete "$legacy_device"
pass "foreign legacy-priority filter is preserved"

new_pref_device="new-pref-test"
ip link add "$new_pref_device" type dummy
ip link set "$new_pref_device" up
tc qdisc add dev "$new_pref_device" clsact
tc filter add dev "$new_pref_device" ingress pref 49150 protocol ip \
    flower src_ip 198.51.100.9/32 action pass
INTERFACE="$new_pref_device"
IFB_NAME="$FOREIGN_IFB"
if (setup_network "$new_pref_device" >/tmp/iplimit-conflict.log 2>&1); then
    fail "startup accepted a foreign new-priority filter"
fi
tc filter show dev "$new_pref_device" ingress pref 49150 | grep -q '198.51.100.9' \
    || fail "startup deleted a foreign new-priority filter"
tc filter del dev "$new_pref_device" ingress pref 49150 protocol ip
tc qdisc del dev "$new_pref_device" clsact
ip link delete "$new_pref_device"
rm -rf "$IPLIMIT_STATE_DIR"
pass "foreign new-priority filter is refused and preserved"

INTERFACE="$TEST_INTERFACE"
IFB_NAME="ifb-iptest"

ip netns add "$TEST_NAMESPACE"
ip link add "$TEST_INTERFACE" type veth peer name "$TEST_PEER"
ip link set "$TEST_PEER" netns "$TEST_NAMESPACE"
ip addr add 203.0.113.10/24 dev "$TEST_INTERFACE"
ip -6 addr add 2001:db8:1::10/64 dev "$TEST_INTERFACE"
ip link set "$TEST_INTERFACE" up
ip netns exec "$TEST_NAMESPACE" ip addr add 203.0.113.20/24 dev "$TEST_PEER"
ip netns exec "$TEST_NAMESPACE" ip addr add 203.0.113.30/24 dev "$TEST_PEER"
ip netns exec "$TEST_NAMESPACE" ip link set lo up
ip netns exec "$TEST_NAMESPACE" ip link set "$TEST_PEER" up

tc qdisc add dev "$TEST_INTERFACE" clsact
tc filter add dev "$TEST_INTERFACE" egress pref 10 protocol all matchall action pass
mkdir -p "$IPLIMIT_STATE_DIR"
{
    printf 'INTERFACE=%s\n' "$TEST_INTERFACE"
    printf 'IFB_NAME=%s\n' "$IFB_NAME"
    printf 'CREATED_CLSACT=0\n'
} >"$OWNER_FILE"
ip link add "$IFB_NAME" type ifb
ip link set "$IFB_NAME" up
tc filter add dev "$TEST_INTERFACE" ingress pref 49152 protocol all \
    matchall action mirred egress redirect dev "$IFB_NAME"
setup_network "$TEST_INTERFACE"

if tc filter show dev "$TEST_INTERFACE" ingress | grep -q 'matchall'; then
    fail "ingress must not redirect all packets to IFB"
fi
pass "no global ingress matchall redirect"

before_default=$(class_packets "$IFB_NAME" 1:1)
ip netns exec "$TEST_NAMESPACE" ping -q -c 20 -i 0.01 -W 1 -I 203.0.113.30 203.0.113.10 >/dev/null
after_default=$(class_packets "$IFB_NAME" 1:1)
[[ "$after_default" == "$before_default" ]] || fail "unregistered ingress traffic entered IFB"
pass "unregistered ingress bypasses IFB"

add_client_class "$TEST_INTERFACE" 203.0.113.20 10
add_client_class "$TEST_INTERFACE" 203.0.113.21 11
add_client_class "$TEST_INTERFACE" 2001:db8:2::20 12

wan_filters=$(tc filter show dev "$TEST_INTERFACE" parent 1:)
ifb_filters=$(tc filter show dev "$IFB_NAME" parent 1:)
ingress_filters=$(tc filter show dev "$TEST_INTERFACE" ingress)

grep -q 'pref 49150' <<<"$wan_filters" || fail "WAN IPv4 filters do not share priority 49150"
grep -q 'handle 0xa' <<<"$wan_filters" || fail "WAN filter handle 0xa missing"
grep -q 'handle 0xb' <<<"$wan_filters" || fail "WAN filter handle 0xb missing"
grep -q 'pref 49151' <<<"$wan_filters" || fail "WAN IPv6 priority 49151 missing"
grep -q 'pref 49150' <<<"$ifb_filters" || fail "IFB IPv4 filters do not share priority 49150"
grep -q 'src_ip 203.0.113.20' <<<"$ingress_filters" || fail "client ingress redirect missing"
grep -q 'src_ip 203.0.113.21' <<<"$ingress_filters" || fail "second client ingress redirect missing"
grep -q 'pref 49151' <<<"$ingress_filters" || fail "IPv6 ingress priority 49151 missing"
pass "same-family flower filters share priorities and retain handles"

before_client=$(class_packets "$IFB_NAME" 1:a)
ip netns exec "$TEST_NAMESPACE" ping -q -c 20 -i 0.01 -W 1 -I 203.0.113.20 203.0.113.10 >/dev/null
after_client=$(class_packets "$IFB_NAME" 1:a)
((after_client > before_client)) || fail "registered client upload did not enter its IFB class"
pass "registered client upload is shaped through IFB"

remove_client_class "$TEST_INTERFACE" 203.0.113.20 10
if tc filter show dev "$TEST_INTERFACE" ingress | grep -q 'src_ip 203.0.113.20'; then
    fail "removed client ingress filter remains"
fi
tc filter show dev "$TEST_INTERFACE" ingress | grep -q 'src_ip 203.0.113.21' || fail "removing one client deleted another client filter"
pass "one client can be removed by handle"

cleanup_network "$TEST_INTERFACE"
tc qdisc show dev "$TEST_INTERFACE" | grep -q 'clsact' || fail "foreign clsact was removed"
tc filter show dev "$TEST_INTERFACE" egress pref 10 | grep -q 'matchall' || fail "foreign egress filter was removed"
pass "owned cleanup preserves foreign clsact filters"

trap - EXIT
cleanup_test
printf 'tc integration tests passed\n'
