#!/bin/sh
# =========================================
# 作者: jinqians
# 网站：jinqians.com
# 描述: Shadowsocks Rust 管理脚本 (全面兼容 POSIX sh、BusyBox、Alpine、OpenWrt 及各类 Linux 发行版)
# =========================================

# 版本信息
SCRIPT_VERSION="2.0"
SS_VERSION=""

# 系统路径
SCRIPT_PATH=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
SCRIPT_NAME=$(basename "$0")

# 安装路径
INSTALL_DIR="/etc/ss-rust"
BINARY_PATH="/usr/local/bin/ss-rust"
CONFIG_PATH="/etc/ss-rust/config.json"
PORTS_DIR="/etc/ss-rust/ports"
VERSION_FILE="/etc/ss-rust/ver.txt"
SYSCTL_CONF="/etc/sysctl.d/local.conf"
MAINLAND_BLOCK_SCRIPT="/usr/local/bin/block-mainland.sh"
MAINLAND_EXTRACT_SCRIPT="/usr/local/bin/extract-cn-ip-from-mmdb.py"
MAINLAND_BLOCK_REPO_URL="https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/block-mainland.sh"
MAINLAND_EXTRACT_REPO_URL="https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/extract-cn-ip-from-mmdb.py"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'
BOLD='\033[1m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 状态提示
INFO="${GREEN}[信息]${PLAIN}"
ERROR="${RED}[错误]${PLAIN}"
WARNING="${YELLOW}[警告]${PLAIN}"
SUCCESS="${GREEN}[成功]${PLAIN}"

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Red_background_prefix="\033[41;37m"
Font_color_suffix="\033[0m"
Yellow_font_prefix="\033[0;33m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"
Success="${Green_font_prefix}[成功]${Font_color_suffix}"

# 系统信息
OS_TYPE=""
OS_ARCH=""
OS_VERSION=""

# 配置信息
SS_PORT=""
SS_PASSWORD=""
SS_METHOD=""
SS_TFO=""
SS_DNS=""
SS_PLUGIN=""
SS_PLUGIN_OPTS=""

# 错误处理函数
error_exit() {
    echo -e "${ERROR} $1" >&2
    exit 1
}

# 辅助函数：校验纯数字
is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        error_exit "当前非ROOT账号(或没有ROOT权限)，无法继续操作，请使用 sudo 或 su 获取ROOT权限"
    fi
}

# 检测 C 运行库类型 (musl libc vs glibc)
detect_libc() {
    if ldd /bin/sh 2>&1 | grep -qi musl || ldd --version 2>&1 | grep -qi musl || ls /lib/ld-musl* >/dev/null 2>&1; then
        echo "musl"
    else
        echo "gnu"
    fi
}

# 检测操作系统
detect_os() {
    if [ -f /etc/os-release ]; then
        local os_id os_like
        os_id=$(. /etc/os-release 2>/dev/null && echo "${ID:-}")
        os_like=$(. /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}")
        case "${os_id}" in
            debian|ubuntu|linuxmint|kali) OS_TYPE="debian" ;;
            centos|rhel|almalinux|rocky|fedora|ol|amzn|anolis|openEuler) OS_TYPE="centos" ;;
            alpine) OS_TYPE="alpine" ;;
            arch|manjaro) OS_TYPE="arch" ;;
            openwrt) OS_TYPE="openwrt" ;;
            void) OS_TYPE="void" ;;
            *)
                case "${os_like}" in
                    *debian*|*ubuntu*) OS_TYPE="debian" ;;
                    *rhel*|*fedora*|*centos*) OS_TYPE="centos" ;;
                    *arch*) OS_TYPE="arch" ;;
                    *alpine*) OS_TYPE="alpine" ;;
                esac
                ;;
        esac
    fi

    if [ -z "${OS_TYPE}" ]; then
        if [ -f /etc/alpine-release ]; then
            OS_TYPE="alpine"
        elif [ -f /etc/arch-release ]; then
            OS_TYPE="arch"
        elif [ -f /etc/openwrt_release ]; then
            OS_TYPE="openwrt"
        elif [ -f /etc/redhat-release ]; then
            OS_TYPE="centos"
        elif grep -q -E -i "debian" /etc/issue 2>/dev/null; then
            OS_TYPE="debian"
        elif grep -q -E -i "ubuntu" /etc/issue 2>/dev/null; then
            OS_TYPE="ubuntu"
        elif grep -q -E -i "centos|red hat|redhat" /etc/issue 2>/dev/null; then
            OS_TYPE="centos"
        elif command -v apk >/dev/null 2>&1; then
            OS_TYPE="alpine"
        elif command -v opkg >/dev/null 2>&1; then
            OS_TYPE="openwrt"
        elif command -v pacman >/dev/null 2>&1; then
            OS_TYPE="arch"
        elif command -v apt-get >/dev/null 2>&1; then
            OS_TYPE="debian"
        elif command -v yum >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
            OS_TYPE="centos"
        else
            OS_TYPE="linux"
        fi
    fi
}

# RHEL 系包管理器
rhel_pkg_mgr() {
    if command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    else
        echo "yum"
    fi
}

# 检测系统架构 (自动识别 musl libc，适配 Alpine / OpenWrt / BusyBox)
detect_arch() {
    local arch
    arch=$(uname -m)
    local os
    os=$(uname -s)
    local libc
    libc=$(detect_libc)
    
    case "${os}" in
        "Darwin")
            case "${arch}" in
                "arm64") OS_ARCH="aarch64-apple-darwin" ;;
                "x86_64") OS_ARCH="x86_64-apple-darwin" ;;
            esac
            ;;
        "Linux")
            case "${arch}" in
                "x86_64"|"amd64")
                    if [ "$libc" = "musl" ]; then
                        OS_ARCH="x86_64-unknown-linux-musl"
                    else
                        OS_ARCH="x86_64-unknown-linux-gnu"
                    fi
                    ;;
                "aarch64"|"arm64")
                    if [ "$libc" = "musl" ]; then
                        OS_ARCH="aarch64-unknown-linux-musl"
                    else
                        OS_ARCH="aarch64-unknown-linux-gnu"
                    fi
                    ;;
                "armv7"|"armv7l"|"armhf")
                    if [ "$libc" = "musl" ]; then
                        OS_ARCH="armv7-unknown-linux-musleabihf"
                    else
                        OS_ARCH="armv7-unknown-linux-gnueabihf"
                    fi
                    ;;
                "arm"|"armv6"|"armv6l")
                    if [ "$libc" = "musl" ]; then
                        OS_ARCH="arm-unknown-linux-musleabi"
                    else
                        OS_ARCH="arm-unknown-linux-gnueabi"
                    fi
                    ;;
                "i686"|"i386")
                    OS_ARCH="i686-unknown-linux-musl"
                    ;;
                *)
                    error_exit "不支持的CPU架构: ${arch}"
                    ;;
            esac
            ;;
        *)
            error_exit "不支持的操作系统: ${os}"
            ;;
    esac
    
    echo -e "${INFO} 检测到系统架构为 [ ${OS_ARCH} ] (libc: ${libc})"
}

# 检查安装状态
check_installation() {
    if [ ! -e "${BINARY_PATH}" ]; then
        error_exit "Shadowsocks Rust 未安装，请先安装！"
    fi
}

check_installed_status() {
    if [ ! -e "${BINARY_PATH}" ]; then
        echo -e "${Error} Shadowsocks Rust 没有安装，请检查！"
        return 1
    fi
    return 0
}

# 服务管理抽象函数 (兼容 systemd、OpenRC、SysVinit/Busybox)
ss_service_start() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl start "$svc"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" start
    elif [ -x "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" start
    fi
}

ss_service_stop() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" stop 2>/dev/null || true
        rc-update del "$svc" default 2>/dev/null || true
    elif [ -x "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" stop 2>/dev/null || true
    fi
}

ss_service_restart() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl restart "$svc"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" restart
    elif [ -x "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" restart
    fi
}

ss_service_enable() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable "$svc" >/dev/null 2>&1 || true
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add "$svc" default >/dev/null 2>&1 || true
    fi
}

ss_service_disable() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl disable "$svc" 2>/dev/null || true
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update del "$svc" default 2>/dev/null || true
    fi
}

ss_service_is_active() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        [ "$(systemctl is-active "$svc" 2>/dev/null)" = "active" ]
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" status >/dev/null 2>&1
    elif [ -f "/var/run/${svc}.pid" ]; then
        local pid
        pid=$(cat "/var/run/${svc}.pid" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
    elif [ -x "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" status >/dev/null 2>&1
    else
        pgrep -x ss-rust >/dev/null 2>&1 || pidof ss-rust >/dev/null 2>&1
    fi
}

check_service_status() {
    if ss_service_is_active ss-rust; then
        echo "active"
    else
        echo "inactive"
    fi
}

check_status() {
    if ss_service_is_active ss-rust; then
        status="running"
    else
        status="stopped"
    fi
}

# 获取最新版本
get_latest_version() {
    SS_VERSION=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases 2>/dev/null | \
                 jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]' 2>/dev/null)
    
    if [ -z "${SS_VERSION}" ] || [ "${SS_VERSION}" = "null" ]; then
        SS_VERSION="1.25.0"
    fi
    
    SS_VERSION=${SS_VERSION#v}
    echo -e "${INFO} 检测到 Shadowsocks Rust 最新版本为 [ ${SS_VERSION} ]"
}

check_new_ver() {
    new_ver=$(wget -qO- https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases 2>/dev/null | \
              jq -r '[.[] | select(.prerelease == false) | select(.draft == false) | .tag_name] | .[0]' 2>/dev/null)
    if [ -z "${new_ver}" ] || [ "${new_ver}" = "null" ]; then
        new_ver="1.25.0"
    fi
    echo -e "${Info} 检测到 Shadowsocks Rust 最新版本为 [ ${new_ver} ]"
}

check_ver_comparison() {
    if [ ! -f "${VERSION_FILE}" ]; then
        echo -e "${Info} 未找到版本文件，可能是首次安装"
        return 0
    fi
    
    local now_ver
    now_ver=$(cat "${VERSION_FILE}")
    if [ "${now_ver}" != "${new_ver}" ]; then
        echo -e "${Info} 发现 Shadowsocks Rust 新版本 [ ${new_ver} ]"
        echo -e "${Info} 当前版本 [ ${now_ver} ]"
        return 0
    else
        echo -e "${Info} 当前已是最新版本 [ ${new_ver} ]"
        return 1
    fi
}

get_current_version() {
    if [ -f "${VERSION_FILE}" ]; then
        cat "${VERSION_FILE}"
    else
        echo "0.0.0"
    fi
}

# POSIX 兼容版本号对比函数 (无需 bash 数组或 <<<)
version_compare() {
    local cur="${1#v}"
    local lat="${2#v}"
    [ "$cur" = "$lat" ] && return 1

    local c1 c2 c3 l1 l2 l3
    c1=$(echo "$cur" | cut -d. -f1 2>/dev/null); [ -n "$c1" ] || c1=0
    c2=$(echo "$cur" | cut -d. -f2 2>/dev/null); [ -n "$c2" ] || c2=0
    c3=$(echo "$cur" | cut -d. -f3 2>/dev/null); [ -n "$c3" ] || c3=0
    l1=$(echo "$lat" | cut -d. -f1 2>/dev/null); [ -n "$l1" ] || l1=0
    l2=$(echo "$lat" | cut -d. -f2 2>/dev/null); [ -n "$l2" ] || l2=0
    l3=$(echo "$lat" | cut -d. -f3 2>/dev/null); [ -n "$l3" ] || l3=0

    [ "$c1" -lt "$l1" ] 2>/dev/null && return 0
    [ "$c1" -gt "$l1" ] 2>/dev/null && return 1
    [ "$c2" -lt "$l2" ] 2>/dev/null && return 0
    [ "$c2" -gt "$l2" ] 2>/dev/null && return 1
    [ "$c3" -lt "$l3" ] 2>/dev/null && return 0
    return 1
}

# 下载 Shadowsocks Rust
download_ss() {
    local version=$1
    local arch=$2
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${version}"
    local filename=""

    case "${arch}" in
        "aarch64-apple-darwin"|"x86_64-apple-darwin")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        "x86_64-unknown-linux-gnu"|"x86_64-unknown-linux-musl")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        "aarch64-unknown-linux-gnu"|"aarch64-unknown-linux-musl")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        "arm-unknown-linux-gnueabi"|"arm-unknown-linux-gnueabihf"|"arm-unknown-linux-musleabi"|"arm-unknown-linux-musleabihf")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        "armv7-unknown-linux-gnueabihf"|"armv7-unknown-linux-musleabihf")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        "i686-unknown-linux-musl")
            filename="shadowsocks-v${version}.${arch}.tar.xz"
            ;;
        *)
            error_exit "不支持的系统架构: ${arch}"
            ;;
    esac
    
    echo -e "${INFO} 开始下载 Shadowsocks Rust ${version}..."
    echo -e "${INFO} 下载地址：${url}/${filename}"
    wget --no-check-certificate -N "${url}/${filename}"
    
    if [ ! -e "${filename}" ]; then
        error_exit "Shadowsocks Rust 下载失败！"
    fi
    
    case "${filename}" in
        *.tar.xz)
            if ! tar -xf "${filename}"; then
                error_exit "Shadowsocks Rust 解压失败！"
            fi
            ;;
        *.zip)
            if ! unzip -o "${filename}"; then
                error_exit "Shadowsocks Rust 解压失败！"
            fi
            ;;
    esac
    
    if [ ! -e "ssserver" ]; then
        error_exit "Shadowsocks Rust 解压后未找到主程序！"
    fi
    
    rm -f "${filename}"
    chmod +x ssserver
    mkdir -p "$(dirname "${BINARY_PATH}")"
    mv -f ssserver "${BINARY_PATH}"
    rm -f sslocal ssmanager ssservice ssurl
    
    mkdir -p "${INSTALL_DIR}"
    echo "${version}" > "${VERSION_FILE}"
    echo -e "${SUCCESS} Shadowsocks Rust ${version} 下载安装完成！"
}

# 下载
download() {
    if [ ! -e "${INSTALL_DIR}" ]; then
        mkdir -p "${INSTALL_DIR}"
    fi
    download_ss "${SS_VERSION}" "${OS_ARCH}"
}

# 创建通用服务配置 (支持 systemd、OpenRC、SysVinit)
ss_create_service() {
    local svc_name="$1"
    local config_file="$2"
    local port_desc="$3"

    # 1. systemd
    if [ -d /etc/systemd/system ] || [ -d /run/systemd/system ]; then
        mkdir -p /etc/systemd/system
        cat > "/etc/systemd/system/${svc_name}.service" << EOF
[Unit]
Description=Shadowsocks Rust Service ${port_desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BINARY_PATH} -c ${config_file}
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi

    # 2. OpenRC (Alpine Linux)
    if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        local init_file="/etc/init.d/${svc_name}"
        cat > "$init_file" << EOF
#!/sbin/openrc-run
description="Shadowsocks Rust Service ${port_desc}"
command="${BINARY_PATH}"
command_args="-c ${config_file}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/${svc_name}.log"
error_log="/var/log/${svc_name}.log"

depend() {
    need net
}
EOF
        chmod +x "$init_file"
        rc-update add "${svc_name}" default >/dev/null 2>&1 || true
    elif [ -d "/etc/init.d" ] && ! [ -d /run/systemd/system ]; then
        # 3. SysVinit / Busybox init.d
        local init_file="/etc/init.d/${svc_name}"
        cat > "$init_file" << EOF
#!/bin/sh
NAME="${svc_name}"
DAEMON="${BINARY_PATH}"
DAEMON_ARGS="-c ${config_file}"
PIDFILE="/var/run/\${NAME}.pid"
LOGFILE="/var/log/\${NAME}.log"

case "\$1" in
    start)
        echo "Starting \$NAME..."
        if command -v start-stop-daemon >/dev/null 2>&1; then
            start-stop-daemon -S -b -m -p "\$PIDFILE" -x "\$DAEMON" -- \$DAEMON_ARGS
        else
            nohup "\$DAEMON" \$DAEMON_ARGS >> "\$LOGFILE" 2>&1 &
            echo \$! > "\$PIDFILE"
        fi
        ;;
    stop)
        echo "Stopping \$NAME..."
        if command -v start-stop-daemon >/dev/null 2>&1; then
            start-stop-daemon -K -p "\$PIDFILE" 2>/dev/null || true
        elif [ -f "\$PIDFILE" ]; then
            kill "\$(cat "\$PIDFILE")" 2>/dev/null || true
        fi
        rm -f "\$PIDFILE"
        ;;
    restart)
        "\$0" stop
        sleep 1
        "\$0" start
        ;;
    status)
        if [ -f "\$PIDFILE" ] && kill -0 "\$(cat "\$PIDFILE")" 2>/dev/null; then
            echo "\$NAME is running."
            exit 0
        else
            echo "\$NAME is not running."
            exit 1
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
        chmod +x "$init_file"
    fi
}

# 安装主系统服务
install_service() {
    echo -e "${INFO} 开始安装系统服务..."
    ss_create_service "ss-rust" "${CONFIG_PATH}" "(Main)"
    ss_service_enable "ss-rust"
    echo -e "${SUCCESS} Shadowsocks Rust 服务配置完成！"
}

# 确保系统时间同步
ensure_time_sync() {
    echo -e "${INFO} 检查系统时间同步（SS2022 协议要求时间误差在 30 秒内）..."

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl is-active chronyd >/dev/null 2>&1 || \
           systemctl is-active chrony >/dev/null 2>&1 || \
           systemctl is-active systemd-timesyncd >/dev/null 2>&1 || \
           systemctl is-active ntp >/dev/null 2>&1 || \
           systemctl is-active ntpd >/dev/null 2>&1; then
            echo -e "${INFO} 检测到 NTP 时间同步服务已在运行"
            return 0
        fi

        if systemctl list-unit-files systemd-timesyncd.service 2>/dev/null | grep -q "systemd-timesyncd"; then
            if timedatectl set-ntp true 2>/dev/null || systemctl enable --now systemd-timesyncd 2>/dev/null; then
                echo -e "${SUCCESS} 已启用 systemd-timesyncd 时间同步"
                return 0
            fi
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service chronyd status >/dev/null 2>&1 || rc-service ntpd status >/dev/null 2>&1; then
            echo -e "${INFO} 检测到 NTP 时间同步服务已在运行"
            return 0
        fi
        if command -v chronyd >/dev/null 2>&1; then
            rc-service chronyd start >/dev/null 2>&1 || true
            rc-update add chronyd default >/dev/null 2>&1 || true
            return 0
        fi
    fi

    # 尝试单次 ntpd 快速校准 (Busybox / Linux 通用)
    if command -v ntpd >/dev/null 2>&1; then
        ntpd -q -p pool.ntp.org 2>/dev/null || ntpd -q -p time.google.com 2>/dev/null || true
    fi
}

# 安装依赖
install_dependencies() {
    echo -e "${INFO} 开始安装系统依赖..."
    
    if [ "${OS_TYPE}" = "centos" ]; then
        local pkg_mgr
        pkg_mgr=$(rhel_pkg_mgr)
        ${pkg_mgr} install -y epel-release 2>/dev/null || true
        ${pkg_mgr} install -y jq gzip wget curl unzip xz openssl tar || error_exit "系统依赖安装失败，请检查网络和软件源"
        ${pkg_mgr} install -y qrencode 2>/dev/null || echo -e "${WARNING} qrencode 安装失败，二维码功能不可用"
    elif [ "${OS_TYPE}" = "alpine" ]; then
        apk update || true
        apk add --no-cache jq gzip wget curl unzip xz openssl tar tzdata ca-certificates || error_exit "系统依赖安装失败"
        apk add --no-cache qrencode 2>/dev/null || true
    elif [ "${OS_TYPE}" = "arch" ]; then
        pacman -Sy --noconfirm jq gzip wget curl unzip xz openssl tar || error_exit "系统依赖安装失败"
        pacman -Sy --noconfirm qrencode 2>/dev/null || true
    elif [ "${OS_TYPE}" = "openwrt" ]; then
        opkg update || true
        opkg install jq gzip wget-ssl curl unzip xz openssl-util tar ca-certificates || error_exit "系统依赖安装失败"
    elif [ "${OS_TYPE}" = "void" ]; then
        xbps-install -Sy jq gzip wget curl unzip xz openssl tar || error_exit "系统依赖安装失败"
        xbps-install -Sy qrencode 2>/dev/null || true
    else
        apt-get update 2>/dev/null || true
        apt-get install -y jq gzip wget curl unzip xz-utils openssl tar || error_exit "系统依赖安装失败，请检查网络和软件源"
        apt-get install -y qrencode 2>/dev/null || true
    fi
    
    # 设置时区
    echo -e "${CYAN}正在设置时区...${RESET}"
    if [ -f "/usr/share/zoneinfo/Asia/Shanghai" ]; then
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime 2>/dev/null || true
        echo "Asia/Shanghai" > /etc/timezone 2>/dev/null || true
    fi

    # 同步系统时间
    ensure_time_sync

    echo -e "${SUCCESS} 系统依赖安装完成！"
}

# 写入配置文件
write_config() {
    mkdir -p "$(dirname "${CONFIG_PATH}")"
    if ! jq -n \
        --arg server "$(get_ss_listen_addr)" \
        --argjson port "${SS_PORT}" \
        --arg password "${SS_PASSWORD}" \
        --arg method "${SS_METHOD}" \
        --argjson tfo "${SS_TFO}" \
        --arg dns "${SS_DNS}" \
        --arg plugin "${SS_PLUGIN}" \
        --arg plugin_opts "${SS_PLUGIN_OPTS}" \
        '{server: $server, server_port: $port, password: $password, method: $method,
          fast_open: $tfo, mode: "tcp_and_udp", user: "nobody", timeout: 300}
         + (if $dns != "" then {nameserver: $dns} else {} end)
         + (if $plugin != "" then {plugin: $plugin, plugin_opts: $plugin_opts} else {} end)' \
        > "${CONFIG_PATH}"; then
        error_exit "配置文件写入失败！"
    fi
    echo -e "${SUCCESS} 配置文件写入完成！"
}

# 读取配置文件
read_config() {
    if [ ! -e "${CONFIG_PATH}" ]; then
        error_exit "Shadowsocks Rust 配置文件不存在！"
    fi

    SS_PORT=$(jq -r '.server_port' "${CONFIG_PATH}")
    SS_PASSWORD=$(jq -r '.password' "${CONFIG_PATH}")
    SS_METHOD=$(jq -r '.method' "${CONFIG_PATH}")
    SS_TFO=$(jq -r '.fast_open' "${CONFIG_PATH}")
    SS_DNS=$(jq -r '.nameserver // empty' "${CONFIG_PATH}")
    SS_PLUGIN=$(jq -r '.plugin // empty' "${CONFIG_PATH}")
    SS_PLUGIN_OPTS=$(jq -r '.plugin_opts // empty' "${CONFIG_PATH}")
}

# 检查防火墙状态
check_firewall() {
    local port=$1
    echo -e "${INFO} 正在检查防火墙状态并放行端口 ${port}..."
    
    # 检查 ufw
    if command -v ufw >/dev/null 2>&1; then
        if ufw status 2>/dev/null | grep -qw active; then
            ufw allow "${port}"/tcp >/dev/null 2>&1 || true
            ufw allow "${port}"/udp >/dev/null 2>&1 || true
            echo -e "${SUCCESS} UFW 端口开放完成！"
        fi
    fi
    
    # 检查 firewalld
    local firewalld_active=0
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewalld_active=1
        echo -e "${INFO} 检测到 firewalld 防火墙..."
        firewall-cmd --permanent --add-port="${port}"/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${port}"/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        echo -e "${SUCCESS} firewalld 端口开放完成！"
    fi

    # 检查 iptables
    if [ "${firewalld_active}" -eq 0 ] && command -v iptables >/dev/null 2>&1; then
        echo -e "${INFO} 检测到 iptables 防火墙，放行端口 ${port}..."
        iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
        iptables -I INPUT -p udp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
        echo -e "${SUCCESS} iptables 端口开放完成！"
    fi
}

# 关闭防火墙放行规则
close_firewall_port() {
    local port=$1
    [ -z "${port}" ] && return 0
    echo -e "${INFO} 回收端口 ${port} 的防火墙放行规则..."

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
        ufw delete allow "${port}"/tcp >/dev/null 2>&1 || true
        ufw delete allow "${port}"/udp >/dev/null 2>&1 || true
    fi

    local firewalld_active=0
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewalld_active=1
        firewall-cmd --permanent --remove-port="${port}"/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port="${port}"/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if [ "${firewalld_active}" -eq 0 ] && command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p tcp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || break
        done
        while iptables -C INPUT -p udp --dport "${port}" -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p udp --dport "${port}" -j ACCEPT >/dev/null 2>&1 || break
        done
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi
}

# SS 端口变更后同步 ShadowTLS 的后端端口
sync_shadowtls_backend_port() {
    local new_port=$1
    [ -z "${new_port}" ] && return 0

    local svc=""
    [ -f "/etc/systemd/system/shadowtls-ss.service" ] && svc="/etc/systemd/system/shadowtls-ss.service"
    [ -z "$svc" ] && [ -f "/etc/init.d/shadowtls-ss" ] && svc="/etc/init.d/shadowtls-ss"
    [ -f "${svc}" ] || return 0

    local cur_backend
    cur_backend=$(sed -n 's/.*--server[[:space:]]*\([^[:space:]]*\).*/\1/p' "${svc}" 2>/dev/null | head -n 1)
    [ -z "${cur_backend}" ] && return 0
    [ "${cur_backend##*:}" = "${new_port}" ] && return 0

    echo -e "${INFO} 检测到 ShadowTLS，正在同步其后端端口 ${cur_backend##*:} -> ${new_port} ..."
    sed -i "s|--server ${cur_backend}|--server 127.0.0.1:${new_port}|" "${svc}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if ss_service_restart shadowtls-ss 2>/dev/null && ss_service_is_active shadowtls-ss; then
        echo -e "${SUCCESS} ShadowTLS 后端端口已同步"
    else
        echo -e "${WARNING} ShadowTLS 重启失败，请检查服务状态"
    fi
}

# 检查端口是否被占用
port_in_use() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -Eq "[:.]${port}([^0-9]|$)" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -Eq "[:.]${port}([^0-9]|$)" && return 0
    fi
    return 1
}

# 生成随机端口
generate_random_port() {
    local min_port=10000
    local max_port=65535
    local port
    local attempts=0
    while [ "$attempts" -lt 20 ]; do
        if command -v shuf >/dev/null 2>&1; then
            port=$(shuf -i "${min_port}-${max_port}" -n 1)
        else
            port=$(awk -v min="$min_port" -v max="$max_port" 'BEGIN {srand(); print int(min + rand() * (max - min + 1))}')
        fi
        if ! port_in_use "${port}"; then
            echo "${port}"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    echo "${port}"
}

# 按加密方式生成符合密钥长度要求的随机密码
generate_password_for_method() {
    local method=$1
    case "${method}" in
        "2022-blake3-aes-128-gcm")
            dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64 | tr -d '\r\n'
            ;;
        "2022-blake3-aes-256-gcm"|"2022-blake3-chacha20-poly1305"|"2022-blake3-chacha8-poly1305")
            dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\r\n'
            ;;
        *)
            dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64 | tr -d '\r\n'
            ;;
    esac
}

# 加密方式要求的密钥字节数
required_key_length() {
    local method=$1
    case "${method}" in
        "2022-blake3-aes-128-gcm") echo 16 ;;
        "2022-blake3-aes-256-gcm"|"2022-blake3-chacha20-poly1305"|"2022-blake3-chacha8-poly1305") echo 32 ;;
        *) echo "" ;;
    esac
}

# 获取 ss-rust 监听地址
get_ss_listen_addr() {
    local has_ipv4=1
    local has_ipv6=0
    [ -f /proc/net/if_inet6 ] && has_ipv6=1
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show scope global 2>/dev/null | grep -q "inet " || has_ipv4=0
    fi

    # 纯 IPv6 机器：只能监听 ::
    if [ "${has_ipv4}" -eq 0 ] && [ "${has_ipv6}" -eq 1 ]; then
        echo "::"
        return
    fi

    # 启用 obfs 插件且有 IPv4：强制 0.0.0.0
    if [ -n "${SS_PLUGIN}" ]; then
        echo "0.0.0.0"
        return
    fi

    # 无插件：有 IPv6 则双栈监听
    if [ "${has_ipv6}" -eq 1 ]; then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

OBFS_HOST="www.bing.com"

build_plugin_param() {
    local plugin=$1
    local plugin_opts=$2
    [ -z "${plugin}" ] && return 0
    local mode="${plugin_opts#obfs=}"
    mode="${mode%%;*}"
    echo "/?plugin=obfs-local%3Bobfs%3D${mode}%3Bobfs-host%3D${OBFS_HOST}"
}

# 设置端口
set_port() {
    local old_port="${SS_PORT}"
    SS_PORT=$(generate_random_port)
    echo -e "${INFO} 已生成随机端口：${SS_PORT}"
    echo -e "${Tip} 是否使用该随机端口？"
    echo "=================================="
    echo -e " ${Green_font_prefix}1.${Font_color_suffix} 是"
    echo -e " ${Green_font_prefix}2.${Font_color_suffix} 否，我要自定义端口"
    echo "=================================="
    
    printf "%b" "(默认: 1. 使用随机端口)："
    read -r port_choice
    [ -z "${port_choice}" ] && port_choice="1"
    
    if [ "${port_choice}" = "2" ]; then
        while true; do
            echo -e "请输入 Shadowsocks Rust 端口 [1-65535]"
            printf "%b" "(默认：2525)："
            read -r SS_PORT
            [ -z "${SS_PORT}" ] && SS_PORT="2525"
            
            if ! is_number "${SS_PORT}"; then
                echo -e "${Error} 输入错误，请输入数字"
                continue
            fi
            if [ "${SS_PORT}" -lt 1 ] || [ "${SS_PORT}" -gt 65535 ]; then
                echo -e "${Error} 输入错误，端口范围必须在 1-65535 之间"
                continue
            fi
            if [ "${SS_PORT}" != "${old_port}" ] && port_in_use "${SS_PORT}"; then
                echo -e "${Error} 端口 ${SS_PORT} 已被其他服务占用，请换一个"
                continue
            fi
            break
        done
    fi
    
    echo && echo "=================================="
    echo -e "端口：${Red_background_prefix} ${SS_PORT} ${Font_color_suffix}"
    echo "=================================="
    
    check_firewall "${SS_PORT}"

    if [ -n "${old_port}" ] && [ "${old_port}" != "${SS_PORT}" ]; then
        close_firewall_port "${old_port}"
    fi
    echo
}

# 设置密码
set_password() {
    local required_len decoded_length
    required_len=$(required_key_length "${SS_METHOD}")

    while true; do
        echo "请输入 Shadowsocks Rust 密码 [0-9][a-z][A-Z]"
        if [ -n "${required_len}" ]; then
            echo -e "${Tip} 当前加密方式 ${SS_METHOD} 要求密码为 ${required_len} 字节密钥的 Base64 编码，建议直接回车随机生成"
        fi
        printf "%b" "(默认：随机生成 Base64)："
        read -r SS_PASSWORD
        if [ -z "${SS_PASSWORD}" ]; then
            SS_PASSWORD=$(generate_password_for_method "${SS_METHOD}")
        fi

        if [ -n "${required_len}" ]; then
            decoded_length=$(printf '%s' "${SS_PASSWORD}" | base64 -d 2>/dev/null | wc -c)
            if [ "${decoded_length}" -ne "${required_len}" ]; then
                echo -e "${WARNING} 密码不符合要求：解码后为 ${decoded_length} 字节，需要 ${required_len} 字节"
                echo -e "${WARNING} 请重新输入，或直接回车由脚本自动生成合规密码"
                continue
            fi
        fi
        break
    done

    echo && echo "=================================="
    echo -e "密码：${Red_background_prefix} ${SS_PASSWORD} ${Font_color_suffix}"
    echo "==================================" && echo
}

# 设置加密方式
set_method() {
    echo -e "请选择 Shadowsocks Rust 加密方式
==================================	
 ${Green_font_prefix} 1.${Font_color_suffix} aes-128-gcm
 ${Green_font_prefix} 2.${Font_color_suffix} aes-256-gcm
 ${Green_font_prefix} 3.${Font_color_suffix} chacha20-ietf-poly1305
 ${Green_font_prefix} 4.${Font_color_suffix} plain
 ${Green_font_prefix} 5.${Font_color_suffix} none
 ${Green_font_prefix} 6.${Font_color_suffix} table
 ${Green_font_prefix} 7.${Font_color_suffix} aes-128-cfb
 ${Green_font_prefix} 8.${Font_color_suffix} aes-256-cfb
 ${Green_font_prefix} 9.${Font_color_suffix} aes-256-ctr 
 ${Green_font_prefix}10.${Font_color_suffix} camellia-256-cfb
 ${Green_font_prefix}11.${Font_color_suffix} rc4-md5
 ${Green_font_prefix}12.${Font_color_suffix} chacha20-ietf
==================================
 ${Tip} AEAD 2022 加密（推荐）
==================================	
 ${Green_font_prefix}13.${Font_color_suffix} 2022-blake3-aes-128-gcm ${Green_font_prefix}(默认)${Font_color_suffix}
 ${Green_font_prefix}14.${Font_color_suffix} 2022-blake3-aes-256-gcm ${Green_font_prefix}(推荐)${Font_color_suffix}
 ${Green_font_prefix}15.${Font_color_suffix} 2022-blake3-chacha20-poly1305
 ${Green_font_prefix}16.${Font_color_suffix} 2022-blake3-chacha8-poly1305
=================================="
    
    printf "%b" "(默认: 13. 2022-blake3-aes-128-gcm)："
    read -r method_choice
    [ -z "${method_choice}" ] && method_choice="13"
    
    case "${method_choice}" in
        1) SS_METHOD="aes-128-gcm" ;;
        2) SS_METHOD="aes-256-gcm" ;;
        3) SS_METHOD="chacha20-ietf-poly1305" ;;
        4) SS_METHOD="plain" ;;
        5) SS_METHOD="none" ;;
        6) SS_METHOD="table" ;;
        7) SS_METHOD="aes-128-cfb" ;;
        8) SS_METHOD="aes-256-cfb" ;;
        9) SS_METHOD="aes-256-ctr" ;;
        10) SS_METHOD="camellia-256-cfb" ;;
        11) SS_METHOD="arc4-md5" ;;
        12) SS_METHOD="chacha20-ietf" ;;
        13) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        14) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        15) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        16) SS_METHOD="2022-blake3-chacha8-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-128-gcm" ;;
    esac
    
    echo && echo "=================================="
    echo -e "加密：${Red_background_prefix} ${SS_METHOD} ${Font_color_suffix}"
    echo "==================================" && echo
}

# 设置 TFO
set_tfo() {
    echo -e "是否启用 TFO ？
==================================
 ${Green_font_prefix}1.${Font_color_suffix} 启用
 ${Green_font_prefix}2.${Font_color_suffix} 禁用
=================================="
    printf "%b" "(默认：1)："
    read -r tfo_choice
    [ -z "${tfo_choice}" ] && tfo_choice="1"
    
    if [ "${tfo_choice}" = "1" ]; then
        SS_TFO="true"
    else
        SS_TFO="false"
    fi
    
    echo && echo "=================================="
    echo -e "TFO：${Red_background_prefix} ${SS_TFO} ${Font_color_suffix}"
    echo "==================================" && echo
}

# 设置 DNS
set_dns() {
    echo -e "请选择 DNS 配置方式：
==================================
 ${Green_font_prefix}1.${Font_color_suffix} 使用系统默认 DNS ${Green_font_prefix}(推荐)${Font_color_suffix}
 ${Green_font_prefix}2.${Font_color_suffix} 自定义 DNS 服务器
=================================="
    printf "%b" "(默认：1)："
    read -r dns_choice
    [ -z "${dns_choice}" ] && dns_choice="1"
    
    if [ "${dns_choice}" = "2" ]; then
        echo -e "请输入自定义 DNS 服务器地址（多个 DNS 用逗号分隔，如：8.8.8.8,8.8.4.4）"
        printf "%b" "(默认：8.8.8.8)："
        read -r SS_DNS
        [ -z "${SS_DNS}" ] && SS_DNS="8.8.8.8"
    else
        SS_DNS=""
    fi
    
    echo && echo "=================================="
    if [ -n "${SS_DNS}" ]; then
        echo -e "DNS：${Red_background_prefix} ${SS_DNS} ${Font_color_suffix}"
    else
        echo -e "DNS：${Red_background_prefix} 系统默认 ${Font_color_suffix}"
    fi
    echo "==================================" && echo
}

# 安装 simple-obfs
install_obfs_plugin() {
    if command -v obfs-server >/dev/null 2>&1; then
        echo -e "${INFO} 检测到已安装 obfs-server"
        return 0
    fi

    [ -z "${OS_TYPE}" ] && detect_os

    if [ "${OS_TYPE}" = "centos" ] || [ "${OS_TYPE}" = "alpine" ]; then
        echo -e "${WARNING} 当前发行版官方源无预编译 simple-obfs 包"
        echo -e "${WARNING} 请自行编译安装 obfs-server 后再启用该插件"
        return 1
    fi

    echo -e "${INFO} 正在安装 simple-obfs..."
    apt-get update 2>/dev/null || true
    if ! apt-get install -y simple-obfs 2>/dev/null; then
        echo -e "${WARNING} simple-obfs 安装失败，请检查软件源"
        return 1
    fi

    if ! command -v obfs-server >/dev/null 2>&1; then
        echo -e "${WARNING} 安装完成但未找到 obfs-server 命令"
        return 1
    fi
    return 0
}

# 设置混淆插件
set_plugin() {
    echo -e "是否启用混淆插件（obfs）？
==================================
 ${Green_font_prefix}1.${Font_color_suffix} 不使用插件 ${Green_font_prefix}(默认)${Font_color_suffix}
 ${Green_font_prefix}2.${Font_color_suffix} simple-obfs (http 混淆)
 ${Green_font_prefix}3.${Font_color_suffix} simple-obfs (tls 混淆)
==================================
 ${Tip} 混淆插件主要用于兼容旧客户端，2022 系列加密本身已足够安全"
    printf "%b" "(默认：1)："
    read -r plugin_choice
    [ -z "${plugin_choice}" ] && plugin_choice="1"

    case "${plugin_choice}" in
        2)
            SS_PLUGIN="obfs-server"
            SS_PLUGIN_OPTS="obfs=http"
            ;;
        3)
            SS_PLUGIN="obfs-server"
            SS_PLUGIN_OPTS="obfs=tls"
            ;;
        *)
            SS_PLUGIN=""
            SS_PLUGIN_OPTS=""
            ;;
    esac

    if [ -n "${SS_PLUGIN}" ]; then
        if ! install_obfs_plugin; then
            echo -e "${WARNING} 插件不可用，本次不启用混淆插件"
            SS_PLUGIN=""
            SS_PLUGIN_OPTS=""
        fi
    fi

    echo && echo "=================================="
    if [ -n "${SS_PLUGIN}" ]; then
        echo -e "插件：${Red_background_prefix} ${SS_PLUGIN} (${SS_PLUGIN_OPTS}) ${Font_color_suffix}"
    else
        echo -e "插件：${Red_background_prefix} 不使用 ${Font_color_suffix}"
    fi
    echo "==================================" && echo
}

# 密码与加密方式校验
ensure_password_matches_method() {
    local required_len decoded_len
    required_len=$(required_key_length "${SS_METHOD}")
    [ -z "${required_len}" ] && return 0

    decoded_len=$(printf '%s' "${SS_PASSWORD}" | base64 -d 2>/dev/null | wc -c)
    [ "${decoded_len}" -eq "${required_len}" ] && return 0

    echo -e "${WARNING} 当前密码解码后为 ${decoded_len} 字节，而 ${SS_METHOD} 要求 ${required_len} 字节"
    echo -e "${WARNING} 加密方式已变更，必须重新设置密码"
    set_password
}

# 修改配置
modify_config() {
    check_installation
    echo && echo -e "你要做什么？
==================================
 ${Green_font_prefix}1.${Font_color_suffix}  修改 端口配置
 ${Green_font_prefix}2.${Font_color_suffix}  修改 密码配置
 ${Green_font_prefix}3.${Font_color_suffix}  修改 加密配置
 ${Green_font_prefix}4.${Font_color_suffix}  修改 TFO 配置
 ${Green_font_prefix}5.${Font_color_suffix}  修改 DNS 配置
 ${Green_font_prefix}6.${Font_color_suffix}  修改 混淆插件配置
 ${Green_font_prefix}7.${Font_color_suffix}  修改 全部配置" && echo
    
    printf "%b" "(默认：取消)："
    read -r modify
    [ -z "${modify}" ] && echo "已取消..." && return 0
    
    case "${modify}" in
        1)
            read_config
            set_port
            write_config
            Restart
            sync_shadowtls_backend_port "${SS_PORT}"
            ;;
        2)
            read_config
            set_password
            write_config
            Restart
            ;;
        3)
            read_config
            set_method
            ensure_password_matches_method
            write_config
            Restart
            ;;
        4)
            read_config
            set_tfo
            write_config
            Restart
            ;;
        5)
            read_config
            set_dns
            write_config
            Restart
            ;;
        6)
            read_config
            set_plugin
            write_config
            Restart
            ;;
        7)
            read_config
            set_port
            set_method
            set_password
            set_tfo
            set_dns
            set_plugin
            write_config
            Restart
            sync_shadowtls_backend_port "${SS_PORT}"
            ;;
        *)
            echo -e "${Error} 请输入正确的数字(1-7)"
            sleep 2
            modify_config
            ;;
    esac
}

# 安装
Install() {
    [ -e "${BINARY_PATH}" ] && echo -e "${Error} 检测到 Shadowsocks Rust 已安装！" && return 1
    
    echo -e "${Info} 检测系统信息..."
    detect_os
    
    echo -e "${Info} 开始设置配置..."
    set_port
    set_method
    set_password
    set_tfo
    set_dns
    set_plugin

    echo -e "${Info} 开始安装/配置依赖..."
    install_dependencies
    
    echo -e "${Info} 开始下载/安装..."
    detect_arch
    get_latest_version
    download
    
    echo -e "${Info} 开始写入配置文件..."
    write_config
    
    echo -e "${Info} 开始安装系统服务..."
    install_service

    echo -e "${Info} 创建命令快捷方式..."
    local cur_script
    cur_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    if [ -f "$cur_script" ]; then
        cp "$cur_script" "/usr/local/bin/ss-2022.sh" 2>/dev/null || true
    fi
    chmod +x "/usr/local/bin/ss-2022.sh" 2>/dev/null || true
    ln -sf "/usr/local/bin/ss-2022.sh" "/usr/local/bin/ssrust" 2>/dev/null || true
    
    echo -e "${Info} 所有步骤安装完毕，开始启动服务..."
    if start_service; then
        echo -e "${Success} Shadowsocks Rust 安装并启动成功！"
        View
        echo -e "${Info} 您可以使用 ${Green_font_prefix}ssrust${Font_color_suffix} 命令进行管理"
        Before_Start_Menu
    else
        echo -e "${Error} Shadowsocks Rust 启动失败，请检查日志！"
        Before_Start_Menu
    fi
}

# 启动服务
start_service() {
    check_installed_status || return 1
    
    echo -e "${INFO} 检查服务状态..."
    check_status
    if [ "$status" = "running" ]; then
        echo -e "${INFO} Shadowsocks Rust 已在运行！"
        return 1
    fi
    
    echo -e "${INFO} 正在启动 Shadowsocks Rust..."
    ss_service_start ss-rust
    sleep 2
    
    if ! ss_service_is_active ss-rust; then
        echo -e "${ERROR} Shadowsocks Rust 启动失败！"
        if command -v journalctl >/dev/null 2>&1; then
            journalctl -xe --unit ss-rust 2>/dev/null || true
        elif [ -f "/var/log/ss-rust.log" ]; then
            tail -n 20 "/var/log/ss-rust.log"
        fi
        return 1
    fi
    
    echo -e "${SUCCESS} Shadowsocks Rust 启动成功！"
}

# 停止
Stop() {
    check_installed_status || return 1
    check_status
    if [ "$status" != "running" ]; then
        echo -e "${Error} Shadowsocks Rust 没有运行，请检查！"
        return 1
    fi
    ss_service_stop ss-rust
    echo -e "${Info} Shadowsocks Rust 已停止！"
}

# 重启
Restart() {
    check_installed_status || return 1
    ss_service_restart ss-rust
    sleep 1
    if ss_service_is_active ss-rust; then
        echo -e "${Info} Shadowsocks Rust 重启完毕！"
        return 0
    fi
    echo -e "${Error} Shadowsocks Rust 重启后未能正常运行！最近日志："
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --no-pager -n 20 -u ss-rust 2>/dev/null || true
    elif [ -f "/var/log/ss-rust.log" ]; then
        tail -n 20 "/var/log/ss-rust.log"
    fi
    echo -e "${Tip} 常见原因：密码长度与加密方式不匹配、端口被占用、插件未安装"
    return 1
}

# 升级
Update() {
    check_installed_status || return 1
    check_new_ver
    check_ver_comparison || return 0
    echo -e "${Info} 是否更新 Shadowsocks Rust？[Y/n]"
    printf "%b" "(默认: y)："
    read -r yn
    [ -z "${yn}" ] && yn="y"
    case "${yn}" in
        [Yy]*)
            detect_arch
            download_ss "${new_ver}" "${OS_ARCH}"
            echo -e "${Info} 重启所有节点服务以应用新版本..."
            ss_service_restart ss-rust
            if [ -d "${PORTS_DIR}" ]; then
                for f in "${PORTS_DIR}"/*.json; do
                    [ -f "$f" ] || continue
                    local p
                    p=$(basename "$f" .json)
                    ss_service_restart "ss-rust-${p}" || echo -e "${WARNING} ss-rust-${p} 重启失败"
                done
            fi
            echo -e "${Success} Shadowsocks Rust 更新完成！"
            ;;
        *)
            echo -e "${Info} 已取消更新..."
            ;;
    esac
}

# 卸载
Uninstall() {
    check_installed_status || return 1
    echo "确定要卸载 Shadowsocks Rust 吗？[y/N]"
    echo
    printf "%b" "(默认：n)："
    read -r unyn
    [ -z "${unyn}" ] && unyn="n"
    case "${unyn}" in
        [Yy]*)
            local main_port=""
            [ -f "${CONFIG_PATH}" ] && main_port=$(jq -r '.server_port // empty' "${CONFIG_PATH}" 2>/dev/null)

            check_status
            [ "$status" = "running" ] && ss_service_stop ss-rust
            ss_service_disable ss-rust
            rm -f "/etc/systemd/system/ss-rust.service" "/etc/init.d/ss-rust"
            [ -n "${main_port}" ] && close_firewall_port "${main_port}"

            # 清理多端口节点服务
            if [ -d /etc/systemd/system ]; then
                for extra_service in /etc/systemd/system/ss-rust-*.service; do
                    [ -f "${extra_service}" ] || continue
                    local svc_name
                    svc_name=$(basename "${extra_service}" .service)
                    local extra_port="${svc_name#ss-rust-}"
                    ss_service_stop "${svc_name}"
                    rm -f "${extra_service}"
                    is_number "${extra_port}" && close_firewall_port "${extra_port}"
                done
            fi
            if [ -d /etc/init.d ]; then
                for extra_init in /etc/init.d/ss-rust-*; do
                    [ -f "${extra_init}" ] || continue
                    local svc_name
                    svc_name=$(basename "${extra_init}")
                    local extra_port="${svc_name#ss-rust-}"
                    ss_service_stop "${svc_name}"
                    rm -f "${extra_init}"
                    is_number "${extra_port}" && close_firewall_port "${extra_port}"
                done
            fi

            if command -v systemctl >/dev/null 2>&1; then
                systemctl daemon-reload >/dev/null 2>&1 || true
            fi

            rm -rf "${INSTALL_DIR}"
            rm -rf "${BINARY_PATH}"
            rm -f "/usr/local/bin/ssrust"
            rm -f "/usr/local/bin/ss-2022.sh"
            echo && echo "Shadowsocks Rust 卸载完成！" && echo
            ;;
        *)
            echo && echo "卸载已取消..." && echo
            ;;
    esac
}

# 获取IPv4地址
getipv4() {
    ipv4=$(curl -m 3 -s4 https://api.ipify.org 2>/dev/null || wget -T 3 -qO- https://api.ipify.org 2>/dev/null || true)
    if [ -z "${ipv4}" ]; then
        ipv4="IPv4_Error"
    fi
}

# 获取IPv6地址
getipv6() {
    ipv6=$(curl -m 3 -s6 https://api64.ipify.org 2>/dev/null || wget -T 3 -qO- https://api64.ipify.org 2>/dev/null || true)
    if [ -z "${ipv6}" ]; then
        ipv6="IPv6_Error"
    fi
}

# SIP002 websafe base64 编码
b64_url() {
    printf '%s' "$1" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '='
}

# 查看配置信息
View() {
    check_installed_status
    getipv4
    getipv6
    
    if [ "${ipv4}" = "IPv4_Error" ] && [ "${ipv6}" = "IPv6_Error" ]; then
        echo -e "${Error} 无法获取 IPv4 或 IPv6 地址，无法输出配置信息！"
        return 1
    fi
    
    if [ -f "${CONFIG_PATH}" ]; then
        local config_port
        config_port=$(jq -r '.server_port' "${CONFIG_PATH}")
        local config_password
        config_password=$(jq -r '.password' "${CONFIG_PATH}")
        local config_method
        config_method=$(jq -r '.method' "${CONFIG_PATH}")
        local config_tfo
        config_tfo=$(jq -r '.fast_open' "${CONFIG_PATH}")
        local config_dns
        config_dns=$(jq -r '.nameserver // empty' "${CONFIG_PATH}")
        local config_plugin
        config_plugin=$(jq -r '.plugin // empty' "${CONFIG_PATH}")
        local config_plugin_opts
        config_plugin_opts=$(jq -r '.plugin_opts // empty' "${CONFIG_PATH}")

        SS_PORT="$config_port"
        SS_PASSWORD="$config_password"
        SS_METHOD="$config_method"
        SS_TFO="$config_tfo"
        SS_DNS="$config_dns"
        SS_PLUGIN="$config_plugin"
        SS_PLUGIN_OPTS="$config_plugin_opts"

        echo -e "Shadowsocks Rust 配置："
        echo -e "——————————————————————————————————"
        [ "${ipv4}" != "IPv4_Error" ] && echo -e " 地址：${Green_font_prefix}${ipv4}${Font_color_suffix}"
        [ "${ipv6}" != "IPv6_Error" ] && echo -e " 地址：${Green_font_prefix}${ipv6}${Font_color_suffix}"
        echo -e " 端口：${Green_font_prefix}${config_port}${Font_color_suffix}"
        echo -e " 密码：${Green_font_prefix}${config_password}${Font_color_suffix}"
        echo -e " 加密：${Green_font_prefix}${config_method}${Font_color_suffix}"
        echo -e " TFO ：${Green_font_prefix}${config_tfo}${Font_color_suffix}"
        [ -n "${config_dns}" ] && echo -e " DNS ：${Green_font_prefix}${config_dns}${Font_color_suffix}"
        [ -n "${config_plugin}" ] && echo -e " 插件：${Green_font_prefix}${config_plugin} (${config_plugin_opts})${Font_color_suffix}"
        echo -e "——————————————————————————————————"
    else
        echo -e "${Error} 配置文件不存在！"
        return 1
    fi

    local userinfo
    userinfo=$(b64_url "${config_method}:${config_password}")
    local ss_url_ipv4=""
    local ss_url_ipv6=""
    local plugin_param=""
    local obfs_mode=""

    if [ -n "${config_plugin}" ]; then
        obfs_mode="${config_plugin_opts#obfs=}"
        obfs_mode="${obfs_mode%%;*}"
        plugin_param=$(build_plugin_param "${config_plugin}" "${config_plugin_opts}")
    fi

    if [ "${ipv4}" != "IPv4_Error" ]; then
        ss_url_ipv4="ss://${userinfo}@${ipv4}:${config_port}${plugin_param}#SS-${ipv4}"
    fi
    if [ "${ipv6}" != "IPv6_Error" ]; then
        ss_url_ipv6="ss://${userinfo}@${ipv6}:${config_port}${plugin_param}#SS-${ipv6}"
    fi

    echo -e "\n${Yellow_font_prefix}=== Shadowsocks 链接 ===${Font_color_suffix}"
    [ -n "${ss_url_ipv4}" ] && echo -e "${Green_font_prefix}IPv4 链接：${Font_color_suffix}${ss_url_ipv4}"
    [ -n "${ss_url_ipv6}" ] && echo -e "${Green_font_prefix}IPv6 链接：${Font_color_suffix}${ss_url_ipv6}"

    echo -e "\n${Yellow_font_prefix}=== Shadowsocks 二维码 ===${Font_color_suffix}"
    if command -v qrencode >/dev/null 2>&1; then
        if [ -n "${ss_url_ipv4}" ]; then
            echo -e "${Green_font_prefix}IPv4 二维码：${Font_color_suffix}"
            echo "${ss_url_ipv4}" | qrencode -t UTF8
        fi
        if [ -n "${ss_url_ipv6}" ]; then
            echo -e "${Green_font_prefix}IPv6 二维码：${Font_color_suffix}"
            echo "${ss_url_ipv6}" | qrencode -t UTF8
        fi
    else
        echo -e "${Red_font_prefix}未安装 qrencode，无法生成二维码${Font_color_suffix}"
    fi

    echo -e "\n${Yellow_font_prefix}=== Surge 配置 ===${Font_color_suffix}"
    local surge_obfs=""
    [ -n "${obfs_mode}" ] && surge_obfs=", obfs=${obfs_mode}, obfs-host=${OBFS_HOST}"
    if [ "${ipv4}" != "IPv4_Error" ]; then
        echo -e "SS-${ipv4} = ss, ${ipv4}, ${config_port}, encrypt-method=${config_method}, password=${config_password}, tfo=${config_tfo}, udp-relay=true${surge_obfs}"
    fi
    if [ "${ipv6}" != "IPv6_Error" ]; then
        echo -e "SS-${ipv6} = ss, ${ipv6}, ${config_port}, encrypt-method=${config_method}, password=${config_password}, tfo=${config_tfo}, udp-relay=true${surge_obfs}"
    fi

    # 检查 ShadowTLS 是否安装并获取配置
    local stls_file=""
    [ -f "/etc/systemd/system/shadowtls-ss.service" ] && stls_file="/etc/systemd/system/shadowtls-ss.service"
    [ -z "$stls_file" ] && [ -f "/etc/init.d/shadowtls-ss" ] && stls_file="/etc/init.d/shadowtls-ss"

    if [ -n "$stls_file" ]; then
        local stls_exec_line
        stls_exec_line=$(grep "shadow-tls" "$stls_file" 2>/dev/null)
        local stls_listen_addr
        stls_listen_addr=$(printf '%s\n' "$stls_exec_line" | sed -n 's/.*--listen[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1)
        local stls_listen_port="${stls_listen_addr##*:}"
        local stls_password
        stls_password=$(printf '%s\n' "$stls_exec_line" | sed -n 's/.*--password[[:space:]]*\([^[:space:]]*\).*/\1/p')
        local stls_sni
        stls_sni=$(printf '%s\n' "$stls_exec_line" | sed -n 's/.*--tls[[:space:]]*\([^[:space:]]*\).*/\1/p')

        echo -e "\n${Yellow_font_prefix}=== ShadowTLS 配置 ===${Font_color_suffix}"
        echo -e " 监听端口：${Green_font_prefix}${stls_listen_port}${Font_color_suffix}"
        echo -e " 密码：${Green_font_prefix}${stls_password}${Font_color_suffix}"
        echo -e " SNI：${Green_font_prefix}${stls_sni}${Font_color_suffix}"
        echo -e " 版本：3"

        local shadow_tls_config="{\"version\":\"3\",\"password\":\"${stls_password}\",\"host\":\"${stls_sni}\",\"port\":\"${stls_listen_port}\",\"address\":\"${ipv4}\"}"
        local shadow_tls_base64
        shadow_tls_base64=$(printf '%s' "${shadow_tls_config}" | base64 | tr -d '\r\n')
        local ss_stls_url="ss://${userinfo}@${ipv4}:${config_port}?shadow-tls=${shadow_tls_base64}#SS-${ipv4}"

        echo -e "\n${Yellow_font_prefix}=== SS + ShadowTLS 链接 ===${Font_color_suffix}"
        [ "${ipv4}" != "IPv4_Error" ] && echo -e "${Green_font_prefix}合并链接：${Font_color_suffix}${ss_stls_url}"

        echo -e "\n${Yellow_font_prefix}=== SS + ShadowTLS 二维码 ===${Font_color_suffix}"
        if command -v qrencode >/dev/null 2>&1; then
            [ "${ipv4}" != "IPv4_Error" ] && echo "${ss_stls_url}" | qrencode -t UTF8
        fi

        echo -e "\n${Yellow_font_prefix}=== Surge Shadowsocks + ShadowTLS 配置 ===${Font_color_suffix}"
        if [ "${ipv4}" != "IPv4_Error" ]; then
            echo -e "SS-${ipv4} = ss, ${ipv4}, ${stls_listen_port}, encrypt-method=${config_method}, password=${config_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
        fi
        if [ "${ipv6}" != "IPv6_Error" ]; then
            echo -e "SS-${ipv6} = ss, ${ipv6}, ${stls_listen_port}, encrypt-method=${config_method}, password=${config_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, udp-relay=true"
        fi
    fi

    echo -e "—————————————————————————"
    return 0
}

# 查看运行状态
Status() {
    echo -e "${Info} 获取 Shadowsocks Rust 活动状态 ……"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl status ss-rust --no-pager || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service ss-rust status || true
    elif [ -x "/etc/init.d/ss-rust" ]; then
        /etc/init.d/ss-rust status || true
    fi
    Before_Start_Menu
}

# 更新脚本
Update_Shell() {
    echo -e "${Info} 当前脚本版本为 [ ${SCRIPT_VERSION} ]"
    echo -e "${Info} 开始检测脚本更新..."
    
    local temp_file="/tmp/ss-2022.sh"
    local update_url="https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/ss-2022.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${update_url}" -o "${temp_file}" 2>/dev/null
    else
        wget -qO "${temp_file}" "${update_url}" 2>/dev/null
    fi

    if [ ! -s "${temp_file}" ]; then
        echo -e "${Error} 下载最新脚本失败！"
        rm -f "${temp_file}"
        return 1
    fi
    
    local sh_new_ver
    sh_new_ver=$(grep -m1 '^SCRIPT_VERSION=' "${temp_file}" | cut -d'"' -f2)
    if [ -z "${sh_new_ver}" ]; then
        echo -e "${Error} 获取最新版本号失败！"
        rm -f "${temp_file}"
        return 1
    fi
    
    if [ "${sh_new_ver}" != "${SCRIPT_VERSION}" ]; then
        echo -e "${Info} 发现新版本 [ ${sh_new_ver} ]"
        echo -e "${Info} 是否更新？[Y/n]"
        printf "%b" "(默认: y)："
        read -r yn
        [ -z "${yn}" ] && yn="y"
        case "${yn}" in
            [Yy]*)
                local target="${SCRIPT_PATH}/${SCRIPT_NAME}"
                case "${SCRIPT_PATH}" in
                    /dev/fd*|/proc/*) target="/usr/local/bin/ss-2022.sh" ;;
                esac

                if [ -f "${target}" ]; then
                    cp "${target}" "${target}.bak.${SCRIPT_VERSION}" 2>/dev/null || true
                fi
                
                mv -f "${temp_file}" "${target}"
                chmod +x "${target}"
                echo -e "${Success} 脚本已更新至 [ ${sh_new_ver} ]"
                echo -e "${Info} 2秒后执行新脚本..."
                sleep 2
                exec "${target}"
                ;;
            *)
                echo -e "${Info} 已取消更新..."
                rm -f "${temp_file}"
                ;;
        esac
    else
        echo -e "${Info} 当前已是最新版本 [ ${sh_new_ver} ]"
        rm -f "${temp_file}"
    fi
}

# 安装 ShadowTLS
install_shadowtls() {
    local script_dir
    script_dir=$(dirname "$0")
    if [ -f "${script_dir}/shadowtls.sh" ]; then
        sh "${script_dir}/shadowtls.sh"
        Before_Start_Menu
        return $?
    fi

    echo -e "${Info} 开始下载 ShadowTLS 安装脚本..."
    local tmp_stls="/tmp/shadowtls.sh"
    local dl_url="https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/shadowtls.sh"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${dl_url}" -o "${tmp_stls}" 2>/dev/null
    else
        wget -qO "${tmp_stls}" "${dl_url}" 2>/dev/null
    fi
    
    if [ ! -s "${tmp_stls}" ]; then
        echo -e "${Error} ShadowTLS 脚本下载失败！"
        rm -f "${tmp_stls}"
        return 1
    fi
    
    chmod +x "${tmp_stls}"
    sh "${tmp_stls}"
    rm -f "${tmp_stls}"
    Before_Start_Menu
}

# 部署中国大陆IP屏蔽脚本
install_mainland_block_scripts() {
    local local_block_script="${SCRIPT_PATH}/block-mainland.sh"
    local local_extract_script="${SCRIPT_PATH}/extract-cn-ip-from-mmdb.py"

    echo -e "${Info} 准备部署中国大陆IP屏蔽脚本..."

    if [ -f "${local_block_script}" ]; then
        cp -f "${local_block_script}" "${MAINLAND_BLOCK_SCRIPT}"
    else
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${MAINLAND_BLOCK_REPO_URL}" -o "${MAINLAND_BLOCK_SCRIPT}" 2>/dev/null
        else
            wget -qO "${MAINLAND_BLOCK_SCRIPT}" "${MAINLAND_BLOCK_REPO_URL}" 2>/dev/null
        fi
    fi

    if [ -f "${local_extract_script}" ]; then
        cp -f "${local_extract_script}" "${MAINLAND_EXTRACT_SCRIPT}"
    else
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL "${MAINLAND_EXTRACT_REPO_URL}" -o "${MAINLAND_EXTRACT_SCRIPT}" 2>/dev/null
        else
            wget -qO "${MAINLAND_EXTRACT_SCRIPT}" "${MAINLAND_EXTRACT_REPO_URL}" 2>/dev/null
        fi
    fi

    if [ ! -s "${MAINLAND_BLOCK_SCRIPT}" ] || [ ! -s "${MAINLAND_EXTRACT_SCRIPT}" ]; then
        echo -e "${Error} 大陆IP屏蔽脚本部署失败，请检查网络"
        return 1
    fi

    chmod +x "${MAINLAND_BLOCK_SCRIPT}" "${MAINLAND_EXTRACT_SCRIPT}"
    echo -e "${Success} 大陆IP屏蔽脚本部署完成"
    return 0
}

run_mainland_block_cmd() {
    local cmd="$1"

    if [ ! -x "${MAINLAND_BLOCK_SCRIPT}" ]; then
        echo -e "${Error} 未找到可执行脚本：${MAINLAND_BLOCK_SCRIPT}"
        return 1
    fi

    if [ -n "${cmd}" ]; then
        PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 sh "${MAINLAND_BLOCK_SCRIPT}" "${cmd}"
    else
        PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 sh "${MAINLAND_BLOCK_SCRIPT}"
    fi
}

# 中国大陆IP屏蔽菜单
mainland_block_menu() {
    check_installed_status || return 1

    if ! install_mainland_block_scripts; then
        Before_Start_Menu
        return 1
    fi

    while true; do
        clear 2>/dev/null || true
        echo -e "${GREEN}============================================${RESET}"
        echo -e "${GREEN}        中国大陆IP屏蔽管理 ${RESET}"
        echo -e "${GREEN}============================================${RESET}"
        echo -e " ${Green_font_prefix}1.${Font_color_suffix} 初始化并启用屏蔽"
        echo -e " ${Green_font_prefix}2.${Font_color_suffix} 更新中国大陆IP库"
        echo -e " ${Green_font_prefix}3.${Font_color_suffix} 查看屏蔽状态"
        echo -e " ${Green_font_prefix}4.${Font_color_suffix} 禁用屏蔽规则"
        echo -e " ${Green_font_prefix}5.${Font_color_suffix} 进入高级菜单"
        echo -e " ${Green_font_prefix}0.${Font_color_suffix} 返回上一级"
        echo -e "${GREEN}============================================${RESET}"
        echo

        printf "%b" " 请输入数字 [0-5]："
        read -r mainland_num
        case "${mainland_num}" in
            1)
                if run_mainland_block_cmd "enable"; then
                    echo -e "${Success} 大陆IP屏蔽启用完成"
                else
                    echo -e "${Error} 大陆IP屏蔽启用失败"
                fi
                ;;
            2)
                if run_mainland_block_cmd "update"; then
                    echo -e "${Success} 大陆IP库更新完成"
                else
                    echo -e "${Error} 大陆IP库更新失败"
                fi
                ;;
            3)
                run_mainland_block_cmd "status" || echo -e "${Error} 状态查询失败"
                ;;
            4)
                if run_mainland_block_cmd "disable"; then
                    echo -e "${Success} 大陆IP屏蔽已禁用"
                else
                    echo -e "${Error} 禁用失败"
                fi
                ;;
            5)
                run_mainland_block_cmd
                ;;
            0)
                return 0
                ;;
            *)
                echo -e "${Error} 请输入正确数字 [0-5]"
                ;;
        esac

        echo && printf "%b" "${Yellow_font_prefix}* 按回车返回此菜单 *${Font_color_suffix}" && read -r _dummy
    done
}

# ========== 多端口节点管理 ==========
# 新增端口节点
add_extra_port() {
    read_config
    mkdir -p "${PORTS_DIR}"

    echo -e "${Tip} 新节点将沿用主配置的加密方式（${SS_METHOD}）、TFO、DNS 与插件设置"

    local main_port="${SS_PORT}"
    local new_port input_port
    while true; do
        new_port=$(generate_random_port)
        printf "%b" "请输入新节点端口 [1-65535]（直接回车使用随机端口 ${new_port}）："
        read -r input_port
        [ -n "${input_port}" ] && new_port="${input_port}"
        if ! is_number "${new_port}" || [ "${new_port}" -lt 1 ] || [ "${new_port}" -gt 65535 ]; then
            echo -e "${Error} 端口必须是 1-65535 之间的数字"
            continue
        fi
        if [ "${new_port}" = "${main_port}" ] || [ -f "${PORTS_DIR}/${new_port}.json" ]; then
            echo -e "${Error} 端口 ${new_port} 已被本脚本的节点使用"
            continue
        fi
        if port_in_use "${new_port}"; then
            echo -e "${Error} 端口 ${new_port} 已被其他服务占用"
            continue
        fi
        break
    done

    local new_password required_len decoded_len
    required_len=$(required_key_length "${SS_METHOD}")
    while true; do
        printf "%b" "请输入新节点密码（直接回车随机生成）："
        read -r new_password
        [ -z "${new_password}" ] && new_password=$(generate_password_for_method "${SS_METHOD}")
        if [ -n "${required_len}" ]; then
            decoded_len=$(printf '%s' "${new_password}" | base64 -d 2>/dev/null | wc -c)
            if [ "${decoded_len}" -ne "${required_len}" ]; then
                echo -e "${WARNING} 密码需为 ${required_len} 字节密钥的 Base64 编码（当前解码后 ${decoded_len} 字节），请重新输入或直接回车随机生成"
                continue
            fi
        fi
        break
    done

    local node_config="${PORTS_DIR}/${new_port}.json"
    if ! jq -n \
        --arg server "$(get_ss_listen_addr)" \
        --argjson port "${new_port}" \
        --arg password "${new_password}" \
        --arg method "${SS_METHOD}" \
        --argjson tfo "${SS_TFO}" \
        --arg dns "${SS_DNS}" \
        --arg plugin "${SS_PLUGIN}" \
        --arg plugin_opts "${SS_PLUGIN_OPTS}" \
        '{server: $server, server_port: $port, password: $password, method: $method,
          fast_open: $tfo, mode: "tcp_and_udp", user: "nobody", timeout: 300}
         + (if $dns != "" then {nameserver: $dns} else {} end)
         + (if $plugin != "" then {plugin: $plugin, plugin_opts: $plugin_opts} else {} end)' \
        > "${node_config}"; then
        rm -f "${node_config}"
        echo -e "${Error} 节点配置写入失败！"
        return 1
    fi

    # 创建独立服务
    ss_create_service "ss-rust-${new_port}" "${node_config}" "(Port ${new_port})"
    ss_service_enable "ss-rust-${new_port}"
    ss_service_restart "ss-rust-${new_port}"
    sleep 2

    if ! ss_service_is_active "ss-rust-${new_port}"; then
        echo -e "${Error} 节点服务启动失败！最近日志："
        if command -v journalctl >/dev/null 2>&1; then
            journalctl --no-pager -n 20 -u "ss-rust-${new_port}" 2>/dev/null || true
        elif [ -f "/var/log/ss-rust-${new_port}.log" ]; then
            tail -n 20 "/var/log/ss-rust-${new_port}.log"
        fi
        return 1
    fi

    check_firewall "${new_port}"

    echo -e "${SUCCESS} 新节点已创建并启动！"
    echo -e "——————————————————————————————————"
    echo -e " 端口：${Green_font_prefix}${new_port}${Font_color_suffix}"
    echo -e " 密码：${Green_font_prefix}${new_password}${Font_color_suffix}"
    echo -e " 加密：${Green_font_prefix}${SS_METHOD}${Font_color_suffix}"
    echo -e "——————————————————————————————————"
    getipv4
    if [ "${ipv4}" != "IPv4_Error" ]; then
        local node_userinfo
        node_userinfo=$(b64_url "${SS_METHOD}:${new_password}")
        local node_plugin_param
        node_plugin_param=$(build_plugin_param "${SS_PLUGIN}" "${SS_PLUGIN_OPTS}")
        echo -e " 链接：${Green_font_prefix}ss://${node_userinfo}@${ipv4}:${new_port}${node_plugin_param}#SS-${ipv4}-${new_port}${Font_color_suffix}"
    fi
}

# 查看所有端口节点
list_extra_ports() {
    read_config
    getipv4

    echo -e "\n${Yellow_font_prefix}=== 端口节点列表 ===${Font_color_suffix}"
    echo -e "${Green_font_prefix}[主节点]${Font_color_suffix} 端口：${SS_PORT}  加密：${SS_METHOD}  密码：${SS_PASSWORD}"

    local found=0
    if [ -d "${PORTS_DIR}" ]; then
        for f in "${PORTS_DIR}"/*.json; do
            [ -f "$f" ] || continue
            found=1
            local port password method node_status
            port=$(jq -r '.server_port' "$f")
            password=$(jq -r '.password' "$f")
            method=$(jq -r '.method' "$f")
            if ss_service_is_active "ss-rust-${port}"; then
                node_status="${Green_font_prefix}运行中${Font_color_suffix}"
            else
                node_status="${Red_font_prefix}未运行${Font_color_suffix}"
            fi
            local node_plugin node_plugin_opts
            node_plugin=$(jq -r '.plugin // empty' "$f")
            node_plugin_opts=$(jq -r '.plugin_opts // empty' "$f")
            echo -e "${Green_font_prefix}[额外节点]${Font_color_suffix} 端口：${port}  加密：${method}  密码：${password}  状态：${node_status}"
            if [ "${ipv4}" != "IPv4_Error" ]; then
                local node_userinfo
                node_userinfo=$(b64_url "${method}:${password}")
                local node_plugin_param
                node_plugin_param=$(build_plugin_param "${node_plugin}" "${node_plugin_opts}")
                echo -e "    链接：ss://${node_userinfo}@${ipv4}:${port}${node_plugin_param}#SS-${ipv4}-${port}"
            fi
        done
    fi

    [ "${found}" -eq 0 ] && echo -e "${Tip} 暂无额外端口节点，可通过\"新增端口节点\"创建"
    echo -e "——————————————————————————————————"
}

# 删除端口节点
delete_extra_port() {
    local ports=""
    local count=0
    if [ -d "${PORTS_DIR}" ]; then
        for f in "${PORTS_DIR}"/*.json; do
            [ -f "$f" ] || continue
            local p
            p=$(basename "$f" .json)
            ports="${ports} ${p}"
            count=$((count + 1))
        done
    fi

    if [ "$count" -eq 0 ]; then
        echo -e "${Tip} 暂无可删除的额外端口节点"
        return 0
    fi

    echo -e "当前额外端口节点：${Green_font_prefix}${ports}${Font_color_suffix}"
    printf "%b" "请输入要删除的端口（默认取消）："
    read -r del_port
    [ -z "${del_port}" ] && echo "已取消..." && return 0

    if [ ! -f "${PORTS_DIR}/${del_port}.json" ]; then
        echo -e "${Error} 端口 ${del_port} 不是本脚本管理的额外节点"
        return 1
    fi

    ss_service_stop "ss-rust-${del_port}"
    ss_service_disable "ss-rust-${del_port}"
    rm -f "/etc/systemd/system/ss-rust-${del_port}.service" "/etc/init.d/ss-rust-${del_port}"
    rm -f "${PORTS_DIR}/${del_port}.json"
    close_firewall_port "${del_port}"
    echo -e "${SUCCESS} 端口节点 ${del_port} 已删除"
}

# 多端口管理菜单
multiport_menu() {
    check_installed_status || return 1
    while true; do
        echo -e "
${CYAN}多端口节点管理${RESET}
==================================
 ${Green_font_prefix}1.${Font_color_suffix} 新增端口节点
 ${Green_font_prefix}2.${Font_color_suffix} 查看端口节点
 ${Green_font_prefix}3.${Font_color_suffix} 删除端口节点
 ${Green_font_prefix}0.${Font_color_suffix} 返回主菜单
=================================="
        printf "%b" " 请输入数字 [0-3]："
        read -r mp_choice
        case "${mp_choice}" in
            1) add_extra_port ;;
            2) list_extra_ports ;;
            3) delete_extra_port ;;
            0) return 0 ;;
            *) echo -e "${Error} 请输入正确数字 [0-3]" ;;
        esac
        echo && printf "%b" "${Yellow_font_prefix}* 按回车返回多端口菜单 *${Font_color_suffix}" && read -r _dummy
    done
}

# 返回主菜单
Before_Start_Menu() {
    echo && printf "%b" "${Yellow_font_prefix}* 按回车返回主菜单 *${Font_color_suffix}" && read -r _dummy
}

# 主菜单
Start_Menu() {
    while true; do
        clear 2>/dev/null || true
        check_root
        detect_os
        action=${1:-}
        echo -e "${GREEN}============================================${RESET}"
        echo -e "${GREEN}          SS - 2022 管理脚本 ${RESET}"
        echo -e "${GREEN}============================================${RESET}"
        echo -e "${GREEN}            作者: jinqian${RESET}"
        echo -e "${GREEN}       网站：https://jinqians.com${RESET}"
        echo -e "${GREEN}============================================${RESET}"
        echo && echo -e "  
 ${Green_font_prefix}0.${Font_color_suffix} 更新脚本
——————————————————————————————————
 ${Green_font_prefix}1.${Font_color_suffix} 安装 Shadowsocks Rust
 ${Green_font_prefix}2.${Font_color_suffix} 更新 Shadowsocks Rust
 ${Green_font_prefix}3.${Font_color_suffix} 卸载 Shadowsocks Rust
——————————————————————————————————
 ${Green_font_prefix}4.${Font_color_suffix} 启动 Shadowsocks Rust
 ${Green_font_prefix}5.${Font_color_suffix} 停止 Shadowsocks Rust
 ${Green_font_prefix}6.${Font_color_suffix} 重启 Shadowsocks Rust
——————————————————————————————————
 ${Green_font_prefix}7.${Font_color_suffix} 设置 配置信息
 ${Green_font_prefix}8.${Font_color_suffix} 查看 配置信息
 ${Green_font_prefix}9.${Font_color_suffix} 查看 运行状态
——————————————————————————————————
 ${Green_font_prefix}10.${Font_color_suffix} 安装 ShadowTLS
 ${Green_font_prefix}11.${Font_color_suffix} 多端口管理
 ${Green_font_prefix}12.${Font_color_suffix} 中国大陆IP屏蔽
 ${Green_font_prefix}13.${Font_color_suffix} 退出脚本
——————————————————————————————————
==================================" && echo

        if [ -e "${BINARY_PATH}" ]; then
            check_status
            if [ "$status" = "running" ]; then
                echo -e " 当前状态：${Green_font_prefix}已安装${Font_color_suffix} 并 ${Green_font_prefix}已启动${Font_color_suffix}"
            else
                echo -e " 当前状态：${Green_font_prefix}已安装${Font_color_suffix} 但 ${Red_font_prefix}未启动${Font_color_suffix}"
            fi
        else
            echo -e " 当前状态：${Red_font_prefix}未安装${Font_color_suffix}"
        fi
        echo
        printf "%b" " 请输入数字 [0-13]："
        read -r num
        case "$num" in
            0)
                Update_Shell
                ;;
            1)
                Install
                ;;
            2)
                Update
                ;;
            3)
                Uninstall
                sleep 2
                ;;
            4)
                start_service
                sleep 2
                ;;
            5)
                Stop
                sleep 2
                ;;
            6)
                Restart
                sleep 2
                ;;
            7)
                modify_config
                ;;
            8)
                View
                echo && printf "%b" "${Yellow_font_prefix}* 按回车返回主菜单 *${Font_color_suffix}" && read -r _dummy
                ;;
            9)
                Status
                ;;
            10)
                install_shadowtls
                ;;
            11)
                multiport_menu
                ;;
            12)
                mainland_block_menu
                ;;
            13)
                echo -e "${Info} 退出脚本..."
                exit 0
                ;;
            *)
                echo -e "${Error} 请输入正确数字 [0-13]"
                sleep 2
                ;;
        esac
    done
}

# 启动脚本
Start_Menu "$@"
