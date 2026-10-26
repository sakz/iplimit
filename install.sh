#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_SLUG="${IPLIMIT_REPO:-sakz/iplimit}"
readonly REPO_REF="${IPLIMIT_REF:-main}"
readonly RAW_BASE="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}"
readonly DESTDIR="${DESTDIR:-}"
SCRIPT_PATH=$0
SCRIPT_DIR=$(cd "$(dirname "$SCRIPT_PATH")" && pwd)
readonly SCRIPT_DIR
INSTALL_WORK_DIR=""

log() {
    printf '[iplimit 安装器] %s\n' "$*"
}

die() {
    printf '[iplimit 安装器] 错误：%s\n' "$*" >&2
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
        die "下载 $name 需要 curl 或 wget"
    fi
}

install_dependencies() {
    [[ ${SKIP_DEPENDENCIES:-0} == "1" ]] && return
    command -v apt-get >/dev/null 2>&1 || die "安装器仅支持使用 apt-get 的 Debian/Ubuntu 系统"
    log "正在安装依赖（bash、iproute2、conntrack、kmod、systemd）"
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
        die "请使用 root 权限运行，例如：curl ... | sudo bash"
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
# 由 iplimit 管理。修改后请运行：sudo iplimit start
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
            log "已升级并重启正在运行的服务"
        fi
    fi

    log "已安装到 /usr/local/bin/iplimit"
    log "运行交互式菜单：sudo iplimit"
    log "或直接启动：sudo iplimit start 20"
}

main "$@"
