#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PASS_COUNT=0

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %d - %s\n' "$PASS_COUNT" "$1"
}

assert_success() {
    local description=$1
    shift
    if "$@"; then
        pass "$description"
    else
        fail "$description"
    fi
}

assert_failure() {
    local description=$1
    shift
    if "$@"; then
        fail "$description"
    else
        pass "$description"
    fi
}

assert_eq() {
    local expected=$1
    local actual=$2
    local description=$3
    if [[ "$expected" == "$actual" ]]; then
        pass "$description"
    else
        printf 'expected: %q\nactual:   %q\n' "$expected" "$actual" >&2
        fail "$description"
    fi
}

export IPLIMIT_LIBRARY_ONLY=1
# shellcheck disable=SC1091
source "$ROOT_DIR/iplimit"

assert_success "accepts an integer Mbps rate" is_valid_rate 20
assert_success "accepts a decimal Mbps rate" is_valid_rate 2.5
assert_failure "rejects a zero rate" is_valid_rate 0
assert_failure "rejects a negative rate" is_valid_rate -1
assert_failure "rejects a malformed rate" is_valid_rate 1Mbps

assert_success "accepts IPv4" is_ip_address 203.0.113.9
assert_failure "rejects out-of-range IPv4" is_ip_address 203.0.113.999
assert_success "accepts IPv6" is_ip_address 2001:db8::10
assert_failure "rejects malformed IPv6" is_ip_address '2001:db8::zz'
assert_failure "rejects truncated IPv6" is_ip_address '1:2:3'
assert_failure "rejects multiple IPv6 compression markers" is_ip_address '2001::db8::1'
assert_failure "rejects overlong IPv6" is_ip_address '1:2:3:4:5:6:7:8:9'
assert_success "accepts IPv4-mapped IPv6" is_ip_address '::ffff:192.0.2.1'
assert_success "accepts a Linux interface name" is_valid_interface_name eth0
assert_failure "rejects an overlong interface name" is_valid_interface_name ifb-iplimit-test

CONNTRACK_SAMPLE=$(cat <<'EOF'
ipv4     2 tcp      6 431999 ESTABLISHED src=198.51.100.7 dst=203.0.113.10 sport=54000 dport=443 src=203.0.113.10 dst=198.51.100.7 sport=443 dport=54000 [ASSURED] mark=0 use=1
ipv4     2 udp      17 29 src=198.51.100.8 dst=203.0.113.10 sport=53000 dport=8443 src=203.0.113.10 dst=198.51.100.8 sport=8443 dport=53000 mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=203.0.113.10 dst=192.0.2.20 sport=40000 dport=443 src=192.0.2.20 dst=203.0.113.10 sport=443 dport=40000 [ASSURED] mark=0 use=1
ipv4     2 icmp     1 10 src=198.51.100.9 dst=203.0.113.10 type=8 code=0 id=1 src=203.0.113.10 dst=198.51.100.9 type=0 code=0 id=1 mark=0 use=1
ipv6     10 udp     17 25 src=2001:db8:2::9 dst=2001:db8:1::10 sport=50000 dport=443 src=2001:db8:1::10 dst=2001:db8:2::9 sport=443 dport=50000 mark=0 use=1
EOF
)
EXPECTED_CLIENTS=$'198.51.100.7\n198.51.100.8\n2001:db8:2::9'
ACTUAL_CLIENTS=$(printf '%s\n' "$CONNTRACK_SAMPLE" | extract_clients '203.0.113.10 2001:db8:1::10' | sort)
assert_eq "$EXPECTED_CLIENTS" "$ACTUAL_CLIENTS" "extracts direct TCP and UDP clients only"

assert_eq 'ip|dst_ip|198.51.100.7/32' "$(filter_spec download 198.51.100.7)" "builds IPv4 download classifier"
assert_eq 'ip|src_ip|198.51.100.7/32' "$(filter_spec upload 198.51.100.7)" "builds IPv4 upload classifier"
assert_eq 'ipv6|dst_ip|2001:db8::7/128' "$(filter_spec download 2001:db8::7)" "builds IPv6 download classifier"
assert_eq 'ipv6|src_ip|2001:db8::7/128' "$(filter_spec upload 2001:db8::7)" "builds IPv6 upload classifier"

APPLY_OUTPUT=$(
    require_root() { :; }
    require_commands() { :; }
    load_config() { :; }
    validate_config() { :; }
    save_config() { :; }
    systemctl() {
        printf 'systemctl %s\n' "$*"
        return 0
    }
    start_limit 35 eth0
)
assert_success "start applies config by restarting the service" grep -q '^systemctl restart iplimit.service$' <<<"$APPLY_OUTPUT"

INSTALL_ROOT=$(mktemp -d)
trap 'rm -rf "$INSTALL_ROOT"' EXIT
DESTDIR="$INSTALL_ROOT" SKIP_DEPENDENCIES=1 bash "$ROOT_DIR/install.sh" >/dev/null

assert_success "installer creates executable command" test -x "$INSTALL_ROOT/usr/local/bin/iplimit"
assert_success "installer creates systemd unit" test -f "$INSTALL_ROOT/etc/systemd/system/iplimit.service"
assert_success "systemd waits for daemon readiness" grep -q '^Type=notify$' "$INSTALL_ROOT/etc/systemd/system/iplimit.service"
assert_success "installer creates default config" test -f "$INSTALL_ROOT/etc/iplimit.conf"
assert_success "installed command has valid syntax" bash -n "$INSTALL_ROOT/usr/local/bin/iplimit"

printf '\n%d tests passed\n' "$PASS_COUNT"
