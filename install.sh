#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_SLUG="${IPLIMIT_REPO:-sakz/iplimit}"
readonly REPO_REF="${IPLIMIT_REF:-main}"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}"
readonly DESTDIR="${DESTDIR:-}"
SCRIPT_PATH=${BASH_SOURCE[0]:-$0}
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" && pwd)
readonly SCRIPT_DIR
INSTALL_WORK_DIR=""

log() {
    printf '[iplimit installer] %s\n' "$*"
}

die() {
    printf '[iplimit installer] ERROR: %s\n' "$*" >&2
    exit 1
}

fetch_file() {
    local name=$1
    local destination=$2

    if [[ -f "$SCRIPT_DIR/install.sh" && -f "$SCRIPT_DIR/$name" && "$SCRIPT_DIR/$name" != "$destination" ]]; then
        cp "$SCRIPT_DIR/$name" "$destination"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$RAW_BASE/$name" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$RAW_BASE/$name"
    else
        die "curl or wget is required to download $name"
    fi
}

install_dependencies() {
    [[ ${SKIP_DEPENDENCIES:-0} == "1" ]] && return
    command -v apt-get >/dev/null 2>&1 || die "This installer supports Debian/Ubuntu systems with apt-get"
    log "installing dependencies (bash, iproute2, conntrack, kmod, systemd)"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends bash iproute2 conntrack kmod systemd ca-certificates
}

atomic_install() {
    local source_file=$1
    local destination=$2
    local mode=$3
    local tmp="${destination}.tmp.$$"
    install -m "$mode" "$source_file" "$tmp"
    mv -f "$tmp" "$destination"
}

main() {
    if [[ -z "$DESTDIR" && $(id -u) -ne 0 ]]; then
        die "Run the installer as root, for example: curl ... | sudo bash"
    fi

    install_dependencies

    local bin_dir="$DESTDIR/usr/local/bin"
    local unit_dir="$DESTDIR/etc/systemd/system"
    local config_dir="$DESTDIR/etc"
    INSTALL_WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$INSTALL_WORK_DIR"' EXIT

    install -d -m 755 "$bin_dir" "$unit_dir" "$config_dir"
    fetch_file iplimit "$INSTALL_WORK_DIR/iplimit"
    fetch_file iplimit.service "$INSTALL_WORK_DIR/iplimit.service"
    bash -n "$INSTALL_WORK_DIR/iplimit"

    atomic_install "$INSTALL_WORK_DIR/iplimit" "$bin_dir/iplimit" 755
    atomic_install "$INSTALL_WORK_DIR/iplimit.service" "$unit_dir/iplimit.service" 644

    if [[ ! -e "$config_dir/iplimit.conf" ]]; then
        cat >"$config_dir/iplimit.conf" <<'EOF'
# Managed by iplimit. Edit values, then run: sudo iplimit start
RATE_MBIT="20"
INTERFACE="auto"
IFB_NAME="ifb-iplimit"
POLL_INTERVAL="2"
CLIENT_TTL="300"
UNSHAPED_RATE_MBIT="100000"
EXCLUDE_IPS=""
EOF
        chmod 600 "$config_dir/iplimit.conf"
    fi

    if [[ -z "$DESTDIR" ]]; then
        systemctl daemon-reload
        if systemctl is-active --quiet iplimit.service; then
            systemctl restart iplimit.service
            log "upgraded and restarted the active service"
        fi
    fi

    log "installed /usr/local/bin/iplimit"
    log "run: sudo iplimit"
    log "or start directly: sudo iplimit start 20"
}

main "$@"
