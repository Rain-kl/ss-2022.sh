#!/bin/sh
# =========================================
# 作者: jinqians
# 网站：jinqians.com
# 描述: 这个脚本用于安装和管理 ShadowTLS V3 (支持 POSIX sh、BusyBox、Alpine 及各类 Linux 发行版)
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 定义系统路径
INSTALL_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/shadowtls"
SERVICE_FILE="${SYSTEMD_DIR}/shadowtls.service"

# 定义配置目录
SNELL_CONF_DIR="/etc/snell"
SNELL_CONF_FILE="${SNELL_CONF_DIR}/users/snell-main.conf"
USERS_DIR="${SNELL_CONF_DIR}/users"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 辅助函数：校验纯数字
is_number() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# 安装必要的工具（兼容 Debian/Ubuntu、RHEL 系、Alpine、Arch、OpenWrt 等）
install_requirements() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y wget curl jq qrencode
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add --no-cache wget curl jq qrencode
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y epel-release 2>/dev/null || true
        dnf install -y wget curl jq qrencode
    elif command -v yum >/dev/null 2>&1; then
        yum install -y epel-release 2>/dev/null || true
        yum install -y wget curl jq qrencode
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm wget curl jq qrencode
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install wget-ssl curl jq
    elif command -v xbps-install >/dev/null 2>&1; then
        xbps-install -Sy wget curl jq qrencode
    else
        echo -e "${YELLOW}未识别的包管理器，跳过依赖安装，请确保已安装 wget/curl/jq${RESET}"
    fi
}

# ShadowTLS 监听地址：有 IPv4 时监听 0.0.0.0，纯 IPv6 机器监听 ::0
get_listen_address() {
    if ip -4 addr show scope global 2>/dev/null | grep -q "inet "; then
        echo "0.0.0.0"
    else
        echo "::0"
    fi
}

# 从 service 或 init 文件解析 ShadowTLS 监听端口（兼容 POSIX sed，无需 grep -oP）
get_stls_listen_port() {
    local service_file=$1
    local listen_addr
    listen_addr=$(sed -n 's/.*--listen[[:space:]]*\([^[:space:]]*\).*/\1/p' "$service_file" 2>/dev/null | head -n 1)
    echo "${listen_addr##*:}"
}

# 获取最新版本
get_latest_version() {
    local latest_version
    latest_version=$(curl -s "https://api.github.com/repos/ihciah/shadow-tls/releases/latest" | jq -r .tag_name 2>/dev/null)
    if [ -z "$latest_version" ] || [ "$latest_version" = "null" ]; then
        latest_version="v0.2.25"
    fi
    echo "$latest_version"
}

# 检查 SS 是否已安装
check_ssrust() {
    if [ ! -f "/usr/local/bin/ss-rust" ]; then
        return 1
    fi
    return 0
}

# 检查 Snell 是否已安装
check_snell() {
    if [ ! -f "/usr/local/bin/snell-server" ]; then
        return 1
    fi
    return 0
}

# 获取 SS 端口
get_ssrust_port() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local port
    port=$(jq -r '.server_port' "$ssrust_conf" 2>/dev/null)
    echo "$port"
}

# 获取 SS 密码
get_ssrust_password() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local password
    password=$(jq -r '.password' "$ssrust_conf" 2>/dev/null)
    echo "$password"
}

# 获取 SS 加密方式
get_ssrust_method() {
    local ssrust_conf="/etc/ss-rust/config.json"
    if [ ! -f "$ssrust_conf" ]; then
        return 1
    fi
    local method
    method=$(jq -r '.method' "$ssrust_conf" 2>/dev/null)
    echo "$method"
}

# 获取 Snell 主配置端口
get_snell_port() {
    if [ ! -f "${SNELL_CONF_FILE}" ]; then
        return 1
    fi
    local port
    port=$(grep -E '^listen' "${SNELL_CONF_FILE}" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
    echo "$port"
}

# 获取 Snell 主配置密码
get_snell_password() {
    if [ ! -f "${SNELL_CONF_FILE}" ]; then
        return 1
    fi
    local password
    password=$(grep -E '^psk' "${SNELL_CONF_FILE}" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')
    echo "$password"
}

# 获取所有 Snell 用户配置 (端口|PSK 格式)
get_all_snell_users() {
    # 检查主配置
    local main_port=""
    local main_psk=""
    if [ -f "${SNELL_CONF_FILE}" ]; then
        main_port=$(grep -E '^listen' "${SNELL_CONF_FILE}" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
        main_psk=$(grep -E '^psk' "${SNELL_CONF_FILE}" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')
        if [ -n "$main_port" ] && [ -n "$main_psk" ]; then
            echo "${main_port}|${main_psk}"
        fi
    fi
    
    # 获取其他用户配置
    if [ -d "${USERS_DIR}" ]; then
        for user_conf in "${USERS_DIR}"/snell-*.conf; do
            [ -f "$user_conf" ] || continue
            case "$user_conf" in
                *snell-main.conf) continue ;;
            esac
            local port
            port=$(grep -E '^listen' "$user_conf" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
            local psk
            psk=$(grep -E '^psk' "$user_conf" 2>/dev/null | awk -F'=' '{print $2}' | tr -d ' ')
            if [ -n "$port" ] && [ -n "$psk" ]; then
                echo "${port}|${psk}"
            fi
        done
    fi
}

# 获取 Snell 版本
get_snell_version() {
    if ! command -v snell-server >/dev/null 2>&1; then
        return 1
    fi
    local version_output
    version_output=$(snell-server --v 2>&1)
    if echo "$version_output" | grep -q "v5"; then
        echo "5"
    else
        echo "4"
    fi
}

# 获取服务器IP
get_server_ip() {
    local ipv4
    local ipv6
    ipv4=$(curl -s -4 ip.sb 2>/dev/null || curl -s -4 ifconfig.me 2>/dev/null)
    ipv6=$(curl -s -6 ip.sb 2>/dev/null || curl -s -6 ifconfig.me 2>/dev/null)
    
    if [ -n "$ipv4" ] && [ -n "$ipv6" ]; then
        echo "$ipv4"
    elif [ -n "$ipv4" ]; then
        echo "$ipv4"
    elif [ -n "$ipv6" ]; then
        echo "$ipv6"
    else
        echo -e "${RED}无法获取服务器 IP${RESET}"
        return 1
    fi
}

# 生成随机端口 (兼容 POSIX / BusyBox)
generate_random_port() {
    local min_port=10000
    local max_port=65535
    if command -v shuf >/dev/null 2>&1; then
        shuf -i "${min_port}-${max_port}" -n 1
    else
        awk -v min="$min_port" -v max="$max_port" 'BEGIN {srand(); print int(min + rand() * (max - min + 1))}'
    fi
}

# 检查端口是否被占用 (兼容 ss / netstat)
check_port_usage() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -Eq "[:.]${port}([^0-9]|$)" && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -Eq "[:.]${port}([^0-9]|$)" && return 0
    fi
    return 1
}

# 列出某端口的监听情况
show_port_listeners() {
    local port=$1
    local out=""
    if command -v ss >/dev/null 2>&1; then
        out=$(ss -tulnp 2>/dev/null | awk -v p="$port" 'NR==1 || $5 ~ "[:.]"p"$"')
    elif command -v netstat >/dev/null 2>&1; then
        out=$(netstat -tulnp 2>/dev/null | awk -v p="$port" '$4 ~ "[:.]"p"$"')
    else
        return 0
    fi
    if [ -n "$out" ]; then
        echo -e "${YELLOW}端口 ${port} 监听情况：${RESET}"
        echo "$out"
    fi
}

# 防火墙放行 ShadowTLS 监听端口
open_firewall_port() {
    local port=$1
    [ -z "$port" ] && return 0
    echo -e "${CYAN}正在放行防火墙端口 ${port} ...${RESET}"

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
        ufw allow ${port}/tcp >/dev/null 2>&1 || true
        ufw allow ${port}/udp >/dev/null 2>&1 || true
        echo -e "${GREEN}UFW 已放行端口 ${port}${RESET}"
    fi

    local firewalld_active=0
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewalld_active=1
        firewall-cmd --permanent --add-port=${port}/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${port}/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        echo -e "${GREEN}firewalld 已放行端口 ${port}${RESET}"
    fi

    if [ $firewalld_active -eq 0 ] && command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport ${port} -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p tcp --dport ${port} -j ACCEPT >/dev/null 2>&1 || true
        iptables -C INPUT -p udp --dport ${port} -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p udp --dport ${port} -j ACCEPT >/dev/null 2>&1 || true
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
        echo -e "${GREEN}iptables 已放行端口 ${port}${RESET}"
    fi
}

# 卸载时回收防火墙放行规则
close_firewall_port() {
    local port=$1
    [ -z "$port" ] && return 0

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qw active; then
        ufw delete allow ${port}/tcp >/dev/null 2>&1 || true
        ufw delete allow ${port}/udp >/dev/null 2>&1 || true
    fi

    local firewalld_active=0
    if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewalld_active=1
        firewall-cmd --permanent --remove-port=${port}/tcp >/dev/null 2>&1 || true
        firewall-cmd --permanent --remove-port=${port}/udp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    if [ $firewalld_active -eq 0 ] && command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p tcp --dport ${port} -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p tcp --dport ${port} -j ACCEPT >/dev/null 2>&1 || break
        done
        while iptables -C INPUT -p udp --dport ${port} -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p udp --dport ${port} -j ACCEPT >/dev/null 2>&1 || break
        done
        if command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables.rules 2>/dev/null || true
        fi
    fi
}

# 获取已使用的 ShadowTLS 端口（纯 POSIX 字符串列表）
get_used_stls_ports() {
    local used_ports=""
    
    # 检查 SS 服务
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    if [ -f "$ss_service" ]; then
        local ss_port
        ss_port=$(get_stls_listen_port "$ss_service")
        [ -n "$ss_port" ] && used_ports="${used_ports} ${ss_port}"
    fi
    if [ -f "/etc/init.d/shadowtls-ss" ]; then
        local ss_port
        ss_port=$(get_stls_listen_port "/etc/init.d/shadowtls-ss")
        [ -n "$ss_port" ] && used_ports="${used_ports} ${ss_port}"
    fi

    # 检查 Snell 服务 (systemd)
    if [ -d "${SYSTEMD_DIR}" ]; then
        for service_file in "${SYSTEMD_DIR}"/shadowtls-snell-*.service; do
            [ -f "$service_file" ] || continue
            local port
            port=$(get_stls_listen_port "$service_file")
            [ -n "$port" ] && used_ports="${used_ports} ${port}"
        done
    fi

    # 检查 Snell 服务 (init.d)
    if [ -d "/etc/init.d" ]; then
        for service_file in /etc/init.d/shadowtls-snell-*; do
            [ -f "$service_file" ] || continue
            local port
            port=$(get_stls_listen_port "$service_file")
            [ -n "$port" ] && used_ports="${used_ports} ${port}"
        done
    fi
    
    echo "$used_ports"
}

# 验证并获取可用端口
get_available_port() {
    local port=$1
    local used_ports
    used_ports=$(get_used_stls_ports)
    
    # 如果用户指定了端口
    if [ -n "$port" ]; then
        if ! is_number "$port" || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
            echo -e "${RED}端口必须是 1-65535 之间的数字${RESET}" >&2
            return 1
        fi

        for used_port in $used_ports; do
            if [ "$port" = "$used_port" ]; then
                echo -e "${RED}端口 ${port} 已被其他 ShadowTLS 服务使用${RESET}" >&2
                return 1
            fi
        done
        
        if check_port_usage "$port"; then
            echo -e "${RED}端口 ${port} 已被其他服务占用${RESET}" >&2
            return 1
        fi
        
        echo "$port"
        return 0
    fi
    
    # 生成随机端口
    local attempts=0
    while [ $attempts -lt 10 ]; do
        local random_port
        random_port=$(generate_random_port)
        local is_used=0
        
        for used_port in $used_ports; do
            if [ "$random_port" = "$used_port" ]; then
                is_used=1
                break
            fi
        done
        
        if [ $is_used -eq 0 ] && ! check_port_usage "$random_port"; then
            echo "$random_port"
            return 0
        fi
        
        attempts=$((attempts + 1))
    done
    
    echo -e "${RED}无法找到可用端口${RESET}" >&2
    return 1
}

# 基础服务启停抽象
stls_service_start() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl start "$svc"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" start
    elif [ -x "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" start
    fi
}

stls_service_stop() {
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

stls_service_restart() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl restart "$svc"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" restart
    elif [ -x "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" restart
    fi
}

stls_service_enable() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl enable "$svc" >/dev/null 2>&1 || true
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add "$svc" default >/dev/null 2>&1 || true
    fi
}

stls_service_is_active() {
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
        pgrep -x shadow-tls >/dev/null 2>&1 || pidof shadow-tls >/dev/null 2>&1
    fi
}

stls_service_status() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl status "$svc" --no-pager 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" status 2>/dev/null || true
    elif [ -x "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" status 2>/dev/null || true
    fi
}

# 创建服务文件（支持 systemd、OpenRC、SysVinit/BusyBox）
create_shadowtls_service() {
    local service_type=$1  # ss 或 snell
    local port=$2
    local listen_port=$3
    local tls_domain=$4
    local password=$5
    local service_name
    local description
    local identifier
    
    if [ "$service_type" = "ss" ]; then
        service_name="shadowtls-ss"
        description="Shadow-TLS Server Service for Shadowsocks"
        identifier="shadow-tls-ss"
    else
        service_name="shadowtls-snell-${port}"
        description="Shadow-TLS Server Service for Snell (Port: ${port})"
        identifier="shadow-tls-snell-${port}"
    fi

    # 1. systemd 配置
    if [ -d "${SYSTEMD_DIR}" ] || [ -d /run/systemd/system ]; then
        mkdir -p "${SYSTEMD_DIR}"
        local service_file="${SYSTEMD_DIR}/${service_name}.service"
        cat > "$service_file" << EOF
[Unit]
Description=${description}
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=RUST_BACKTRACE=1
Environment=RUST_LOG=info
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen $(get_listen_address):${listen_port} --server 127.0.0.1:${port} --tls ${tls_domain} --password ${password}
StandardOutput=append:/var/log/shadowtls-${identifier}.log
StandardError=append:/var/log/shadowtls-${identifier}.log
SyslogIdentifier=${identifier}
Restart=always
RestartSec=3
LimitNOFILE=65535
Nice=0
IOSchedulingClass=best-effort
IOSchedulingPriority=0
MemoryMax=512M
Environment=RUST_THREADS=1
Environment=MONOIO_FORCE_LEGACY_DRIVER=1

[Install]
WantedBy=multi-user.target
EOF
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload 2>/dev/null || true
        fi
    fi

    # 2. OpenRC 配置 (Alpine 等)
    if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        local init_file="/etc/init.d/${service_name}"
        cat > "$init_file" << EOF
#!/sbin/openrc-run
description="${description}"
command="/usr/local/bin/shadow-tls"
command_args="--v3 server --listen $(get_listen_address):${listen_port} --server 127.0.0.1:${port} --tls ${tls_domain} --password ${password}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/shadowtls-${identifier}.log"
error_log="/var/log/shadowtls-${identifier}.log"

depend() {
    need net
}
EOF
        chmod +x "$init_file"
        rc-update add "${service_name}" default >/dev/null 2>&1 || true
    elif [ -d "/etc/init.d" ] && ! [ -d /run/systemd/system ]; then
        # 3. SysVinit / BusyBox init
        local init_file="/etc/init.d/${service_name}"
        cat > "$init_file" << EOF
#!/bin/sh
NAME="${service_name}"
DAEMON="/usr/local/bin/shadow-tls"
DAEMON_ARGS="--v3 server --listen $(get_listen_address):${listen_port} --server 127.0.0.1:${port} --tls ${tls_domain} --password ${password}"
PIDFILE="/var/run/\${NAME}.pid"
LOGFILE="/var/log/shadowtls-${identifier}.log"

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

# 验证 ShadowTLS 服务是否真的在运行
verify_shadowtls_service() {
    local service_name=$1
    sleep 1
    if ! stls_service_is_active "$service_name"; then
        echo -e "${RED}警告：${service_name} 启动失败，可能原因：${RESET}"
        echo -e "${YELLOW}  1. 端口被其他服务占用${RESET}"
        echo -e "${YELLOW}  2. 后端服务（SS / Snell）未在 127.0.0.1 监听相应端口${RESET}"
        echo -e "${YELLOW}  3. 防火墙拦截${RESET}"
        echo -e "${YELLOW}查看服务状态排查：${RESET}"
        stls_service_status "$service_name"
        return 1
    fi
    echo -e "${GREEN}${service_name} 运行正常${RESET}"
    return 0
}

# 生成 SS 链接和配置
generate_ss_links() {
    local server_ip=$1
    local listen_port=$2
    local ssrust_password=$3
    local ssrust_method=$4
    local stls_password=$5
    local stls_sni=$6
    local backend_port=$7
    
    echo -e "\n${YELLOW}=== 服务器配置 ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nShadowsocks 配置："
    echo -e "  - 端口：${backend_port}"
    echo -e "  - 加密方式：${ssrust_method}"
    echo -e "  - 密码：${ssrust_password}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"
    
    echo -e "\n${GREEN}Surge 配置：${RESET}"
    echo -e "SS + ShadowTLS = ss, ${server_ip}, ${listen_port}, encrypt-method=${ssrust_method}, password=${ssrust_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_sni}, shadow-tls-version=3, client-fingerprint=chrome"
    
    echo -e "\n${GREEN}Clash Meta (Mihomo) 配置：${RESET}"
    cat << EOF
- name: SS + ShadowTLS
  type: ss
  server: ${server_ip}
  port: ${listen_port}
  cipher: ${ssrust_method}
  password: "${ssrust_password}"
  plugin: shadow-tls
  client-fingerprint: chrome
  plugin-opts:
    host: "${stls_sni}"
    password: "${stls_password}"
    version: 3
EOF

    echo -e "\n${GREEN}Shadowrocket 配置说明：${RESET}"
    echo -e "1. 先添加 Shadowsocks 节点："
    echo -e "   - 类型：Shadowsocks"
    echo -e "   - 服务器：${server_ip}"
    echo -e "   - 端口：${listen_port}"
    echo -e "   - 加密方式：${ssrust_method}"
    echo -e "   - 密码：${ssrust_password}"
    echo -e "2. 在该节点的插件设置中添加 ShadowTLS："
    echo -e "   - 插件类型：shadow-tls"
    echo -e "   - 域名/SNI：${stls_sni}"
    echo -e "   - 密码：${stls_password}"
    echo -e "   - 版本：3"
}

# 生成 Snell 链接和配置
generate_snell_links() {
    local server_ip=$1
    local listen_port=$2
    local snell_password=$3
    local stls_password=$4
    local stls_sni=$5
    local snell_port=$6
    
    echo -e "\n${YELLOW}=== 服务器配置 (Snell 端口: ${snell_port}) ===${RESET}"
    echo -e "服务器IP：${server_ip}"
    echo -e "\nSnell 配置："
    echo -e "  - 端口：${snell_port}"
    echo -e "  - PSK：${snell_password}"
    echo -e "\nShadowTLS 配置："
    echo -e "  - 端口：${listen_port}"
    echo -e "  - 密码：${stls_password}"
    echo -e "  - SNI：${stls_sni}"
    echo -e "  - 版本：3"
    
    echo -e "\n${GREEN}Surge 配置：${RESET}"
    local snell_version
    snell_version=$(get_snell_version)
    if [ "$snell_version" = "5" ]; then
        echo -e "Snell v4 + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk = ${snell_password}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
        echo -e "Snell v5 + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk = ${snell_password}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
    else
        echo -e "Snell + ShadowTLS = snell, ${server_ip}, ${listen_port}, psk = ${snell_password}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_sni}, shadow-tls-version = 3"
    fi
}

# 检测系统架构 (全架构 musl 二进制)
detect_arch() {
    ARCH=""
    local m_arch
    m_arch=$(uname -m)
    case "$m_arch" in
        x86_64|amd64)
            ARCH="x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            ARCH="aarch64-unknown-linux-musl"
            ;;
        armv7*|armhf)
            ARCH="armv7-unknown-linux-musleabihf"
            ;;
        arm*)
            ARCH="arm-unknown-linux-musleabi"
            ;;
        *)
            echo -e "${RED}不支持的系统架构: $m_arch${RESET}"
            return 1
            ;;
    esac
}

# 安装 ShadowTLS
install_shadowtls() {
    echo -e "${CYAN}开始安装 ShadowTLS...${RESET}"
    
    # 检查必要工具
    install_requirements
    
    # 检测已安装的协议
    local has_ss=false
    local has_snell=false
    local configure_ss=false
    local configure_snell=false
    
    if check_ssrust; then
        has_ss=true
        echo -e "${GREEN}检测到 Shadowsocks Rust 已安装${RESET}"
    fi
    
    if check_snell; then
        has_snell=true
        echo -e "${GREEN}检测到 Snell 已安装${RESET}"
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}未检测到 Shadowsocks Rust 或 Snell，请先安装其中一个${RESET}"
        return 1
    fi
    
    # 获取系统架构并下载安装 ShadowTLS (全架构 musl 二进制)
    detect_arch || return 1
    local arch="$ARCH"
    
    local version
    version=$(get_latest_version)
    
    local download_url="https://github.com/ihciah/shadow-tls/releases/download/${version}/shadow-tls-${arch}"
    local tmp_bin
    tmp_bin=$(mktemp 2>/dev/null || echo "/tmp/shadow-tls.$$")

    echo -e "${CYAN}正在下载 ShadowTLS (${version})...${RESET}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$download_url" -o "$tmp_bin" 2>/dev/null
    else
        wget -qO "$tmp_bin" "$download_url" 2>/dev/null
    fi
    
    if [ ! -s "$tmp_bin" ]; then
        echo -e "${RED}下载 ShadowTLS 失败，请检查网络${RESET}"
        rm -f "$tmp_bin"
        exit 1
    fi
    
    mkdir -p "$INSTALL_DIR"
    mv "$tmp_bin" "$INSTALL_DIR/shadow-tls"
    chmod +x "$INSTALL_DIR/shadow-tls"
    
    local password
    password=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || awk 'BEGIN{srand(); for(i=0;i<16;i++) printf "%c", int(65+rand()*26)}')
    
    printf "%b" "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): "
    read -r tls_domain
    if [ -z "$tls_domain" ]; then
        tls_domain="www.microsoft.com"
    fi
    
    # 让用户选择要为哪个协议设置 ShadowTLS
    while true; do
        echo -e "\n${YELLOW}请选择要配置的协议：${RESET}"
        echo -e "1. 为 Shadowsocks 配置 ShadowTLS"
        echo -e "2. 为 Snell 配置 ShadowTLS"
        echo -e "3. 为两者都配置 ShadowTLS"
        echo -e "0. 退出"
        
        printf "%b" "请选择 [0-3]: "
        read -r protocol_choice
        
        case "$protocol_choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss; then
                    echo -e "${RED}未安装 Shadowsocks${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=false
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}未安装 Snell${RESET}"
                    continue
                fi
                configure_ss=false
                configure_snell=true
                break
                ;;
            3)
                if ! $has_ss || ! $has_snell; then
                    echo -e "${RED}需要同时安装 Shadowsocks 和 Snell${RESET}"
                    continue
                fi
                configure_ss=true
                configure_snell=true
                break
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
    
    # 配置 Shadowsocks
    if $configure_ss; then
        echo -e "\n${YELLOW}配置 Shadowsocks 的 ShadowTLS...${RESET}"
        local ss_listen_port
        while true; do
            printf "%b" "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): "
            read -r ss_listen_port
            
            ss_listen_port=$(get_available_port "$ss_listen_port")
            if [ $? -eq 0 ]; then
                break
            fi
            echo -e "${YELLOW}请重新输入端口${RESET}"
        done
        
        echo -e "${GREEN}将使用端口: ${ss_listen_port}${RESET}"
        
        local ss_port
        ss_port=$(get_ssrust_port)
        create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
        stls_service_enable "shadowtls-ss"
        stls_service_restart "shadowtls-ss"
        open_firewall_port "$ss_listen_port"
        verify_shadowtls_service "shadowtls-ss"
    fi
    
    # 配置 Snell
    if $configure_snell; then
        echo -e "\n${YELLOW}配置 Snell 的 ShadowTLS...${RESET}"
        local user_configs
        user_configs=$(get_all_snell_users)
        if [ -z "$user_configs" ]; then
            echo -e "${RED}未找到有效的 Snell 用户配置${RESET}"
            return 1
        fi
        
        echo -e "\n${YELLOW}当前的 Snell 端口列表：${RESET}"
        local tmp_snell_cfg
        tmp_snell_cfg=$(mktemp 2>/dev/null || echo "/tmp/snell_cfg.$$")
        printf '%s\n' "$user_configs" > "$tmp_snell_cfg"

        local port_list=""
        local count=0
        while IFS='|' read -r port psk; do
            if [ -n "$port" ]; then
                count=$((count + 1))
                port_list="${port_list} ${port}"
                if [ "$port" = "$(get_snell_port)" ]; then
                    echo -e "${GREEN}${count}. ${port} (主用户)${RESET}"
                else
                    echo -e "${GREEN}${count}. ${port}${RESET}"
                fi
            fi
        done < "$tmp_snell_cfg"
        rm -f "$tmp_snell_cfg"
        
        echo -e "\n${YELLOW}请选择要配置的端口：${RESET}"
        echo -e "1-${count}. 选择单个端口"
        echo -e "0. 为所有端口配置 ShadowTLS"
        
        printf "%b" "请选择: "
        read -r port_choice
        
        if [ "$port_choice" = "0" ]; then
            for port in $port_list; do
                echo -e "\n${YELLOW}为 Snell 端口 ${port} 配置 ShadowTLS${RESET}"
                local stls_port
                while true; do
                    printf "%b" "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): "
                    read -r stls_port
                    
                    stls_port=$(get_available_port "$stls_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}请重新输入端口${RESET}"
                done
                
                echo -e "${GREEN}将使用端口: ${stls_port}${RESET}"
                
                create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                stls_service_enable "shadowtls-snell-${port}"
                stls_service_restart "shadowtls-snell-${port}"
                open_firewall_port "$stls_port"
                verify_shadowtls_service "shadowtls-snell-${port}"
            done
        elif is_number "$port_choice" && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le "$count" ]; then
            local selected_port=""
            local idx=1
            for p in $port_list; do
                if [ "$idx" -eq "$port_choice" ]; then
                    selected_port="$p"
                    break
                fi
                idx=$((idx + 1))
            done

            echo -e "\n${YELLOW}为 Snell 端口 ${selected_port} 配置 ShadowTLS${RESET}"
            local stls_port
            while true; do
                printf "%b" "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): "
                read -r stls_port
                
                stls_port=$(get_available_port "$stls_port")
                if [ $? -eq 0 ]; then
                    break
                fi
                echo -e "${YELLOW}请重新输入端口${RESET}"
            done
            
            echo -e "${GREEN}将使用端口: ${stls_port}${RESET}"
            
            create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
            stls_service_enable "shadowtls-snell-${selected_port}"
            stls_service_restart "shadowtls-snell-${selected_port}"
            open_firewall_port "$stls_port"
            verify_shadowtls_service "shadowtls-snell-${selected_port}"
        else
            echo -e "${RED}无效的选择${RESET}"
            return 1
        fi
    fi
    
    local server_ip
    server_ip=$(get_server_ip)
    
    # 显示所有可用的配置
    if $configure_ss; then
        local ssrust_password
        local ssrust_method
        local ss_port
        ssrust_password=$(get_ssrust_password)
        ssrust_method=$(get_ssrust_method)
        ss_port=$(get_ssrust_port)
        generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
    fi
    
    if $configure_snell; then
        local tmp_out
        tmp_out=$(mktemp 2>/dev/null || echo "/tmp/snell_out.$$")
        printf '%s\n' "$user_configs" > "$tmp_out"
        while IFS='|' read -r port psk; do
            if [ -n "$port" ]; then
                local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                local init_file="/etc/init.d/shadowtls-snell-${port}"
                local stls_port=""
                if [ -f "$service_file" ]; then
                    stls_port=$(get_stls_listen_port "$service_file")
                elif [ -f "$init_file" ]; then
                    stls_port=$(get_stls_listen_port "$init_file")
                fi
                if [ -n "$stls_port" ]; then
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                fi
            fi
        done < "$tmp_out"
        rm -f "$tmp_out"
    fi

    echo -e "\n${GREEN}服务已启动并设置为开机自启${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"
    
    # 停止并禁用 SS 服务
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ] || [ -f "/etc/init.d/shadowtls-ss" ]; then
        local ss_stls_port=""
        [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ] && ss_stls_port=$(get_stls_listen_port "${SYSTEMD_DIR}/shadowtls-ss.service")
        [ -z "$ss_stls_port" ] && [ -f "/etc/init.d/shadowtls-ss" ] && ss_stls_port=$(get_stls_listen_port "/etc/init.d/shadowtls-ss")
        stls_service_stop "shadowtls-ss"
        rm -f "${SYSTEMD_DIR}/shadowtls-ss.service" "/etc/init.d/shadowtls-ss"
        rm -f "/var/log/shadowtls-shadow-tls-ss.log"
        [ -n "$ss_stls_port" ] && close_firewall_port "$ss_stls_port"
    fi
    
    # 停止并禁用所有 Snell 相关的 ShadowTLS 服务
    if [ -d "${SYSTEMD_DIR}" ]; then
        for service_file in "${SYSTEMD_DIR}"/shadowtls-snell-*.service; do
            [ -f "$service_file" ] || continue
            local service_name
            service_name=$(basename "$service_file" .service)
            local snell_stls_port
            snell_stls_port=$(get_stls_listen_port "$service_file")
            local snell_port="${service_name#shadowtls-snell-}"
            stls_service_stop "$service_name"
            rm -f "$service_file"
            rm -f "/var/log/shadowtls-shadow-tls-snell-${snell_port}.log"
            [ -n "$snell_stls_port" ] && close_firewall_port "$snell_stls_port"
        done
    fi

    if [ -d "/etc/init.d" ]; then
        for init_file in /etc/init.d/shadowtls-snell-*; do
            [ -f "$init_file" ] || continue
            local service_name
            service_name=$(basename "$init_file")
            local snell_stls_port
            snell_stls_port=$(get_stls_listen_port "$init_file")
            local snell_port="${service_name#shadowtls-snell-}"
            stls_service_stop "$service_name"
            rm -f "$init_file"
            rm -f "/var/log/shadowtls-shadow-tls-snell-${snell_port}.log"
            [ -n "$snell_stls_port" ] && close_firewall_port "$snell_stls_port"
        done
    fi
    
    # 删除二进制文件
    rm -f "$INSTALL_DIR/shadow-tls"
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    echo -e "${GREEN}ShadowTLS 已成功卸载${RESET}"
}

# 查看配置
view_config() {
    echo -e "\n${CYAN}=== ShadowTLS 配置信息 ===${RESET}"
    
    local has_config=false
    local server_ip
    server_ip=$(get_server_ip)
    
    # 检查 SS 配置
    local ss_service="${SYSTEMD_DIR}/shadowtls-ss.service"
    local ss_init="/etc/init.d/shadowtls-ss"
    local ss_file=""
    [ -f "$ss_service" ] && ss_file="$ss_service"
    [ -z "$ss_file" ] && [ -f "$ss_init" ] && ss_file="$ss_init"

    if [ -n "$ss_file" ]; then
        has_config=true
        local exec_line
        exec_line=$(grep "shadow-tls" "$ss_file" 2>/dev/null)
        local stls_port
        stls_port=$(get_stls_listen_port "$ss_file")
        local stls_password
        stls_password=$(printf '%s\n' "$exec_line" | sed -n 's/.*--password[[:space:]]*\([^[:space:]]*\).*/\1/p')
        local stls_domain
        stls_domain=$(printf '%s\n' "$exec_line" | sed -n 's/.*--tls[[:space:]]*\([^[:space:]]*\).*/\1/p')
        local ss_port
        ss_port=$(get_ssrust_port)
        local ss_password
        ss_password=$(get_ssrust_password)
        local ss_method
        ss_method=$(get_ssrust_method)
        
        echo -e "\n${GREEN}Shadowsocks + ShadowTLS 配置：${RESET}"
        if [ -n "$stls_port" ] && [ -n "$stls_password" ] && [ -n "$stls_domain" ]; then
            echo -e "${YELLOW}Shadowsocks 配置：${RESET}"
            echo -e "  - 端口：${ss_port}"
            echo -e "  - 加密方式：${ss_method}"
            echo -e "  - 密码：${ss_password}"
            
            echo -e "\n${YELLOW}ShadowTLS 配置：${RESET}"
            echo -e "  - 监听端口：${stls_port}"
            echo -e "  - 密码：${stls_password}"
            echo -e "  - SNI：${stls_domain}"
            echo -e "  - 版本：3"
            
            echo -e "\n${GREEN}Surge 配置：${RESET}"
            echo -e "SS + ShadowTLS = ss, ${server_ip}, ${stls_port}, encrypt-method=${ss_method}, password=${ss_password}, shadow-tls-password=${stls_password}, shadow-tls-sni=${stls_domain}, shadow-tls-version=3, client-fingerprint=chrome"
            
            echo -e "\n${GREEN}Clash Meta (Mihomo) 配置：${RESET}"
            cat << EOF
- name: SS + ShadowTLS
  type: ss
  server: ${server_ip}
  port: ${stls_port}
  cipher: ${ss_method}
  password: "${ss_password}"
  plugin: shadow-tls
  client-fingerprint: chrome
  plugin-opts:
    host: "${stls_domain}"
    password: "${stls_password}"
    version: 3
EOF
            
            if stls_service_is_active "shadowtls-ss"; then
                echo -e "\n${GREEN}服务状态：正在运行${RESET}"
                show_port_listeners "$stls_port"
            else
                echo -e "\n${RED}服务状态：未运行${RESET}"
            fi
        else
            echo -e "${RED}配置文件不完整或已损坏${RESET}"
        fi
    fi
    
    # 检查 Snell 配置
    local snell_services=""
    if [ -d "${SYSTEMD_DIR}" ]; then
        snell_services=$(find "${SYSTEMD_DIR}" -name "shadowtls-snell-*.service" 2>/dev/null)
    fi
    if [ -z "$snell_services" ] && [ -d "/etc/init.d" ]; then
        snell_services=$(ls /etc/init.d/shadowtls-snell-* 2>/dev/null)
    fi

    if [ -n "$snell_services" ]; then
        has_config=true
        local user_configs
        user_configs=$(get_all_snell_users)
        
        if [ -n "$user_configs" ]; then
            local processed_ports=""
            local tmp_snell_v
            tmp_snell_v=$(mktemp 2>/dev/null || echo "/tmp/snell_v.$$")
            printf '%s\n' "$user_configs" > "$tmp_snell_v"

            while IFS='|' read -r port psk; do
                [ -n "$port" ] || continue
                case " $processed_ports " in
                    *" $port "*) continue ;;
                esac
                processed_ports="${processed_ports} ${port}"
                
                local service_file="${SYSTEMD_DIR}/shadowtls-snell-${port}.service"
                [ -f "$service_file" ] || service_file="/etc/init.d/shadowtls-snell-${port}"

                if [ -f "$service_file" ]; then
                    local exec_line
                    exec_line=$(grep "shadow-tls" "$service_file" 2>/dev/null)
                    local stls_port
                    stls_port=$(get_stls_listen_port "$service_file")
                    local stls_password
                    stls_password=$(printf '%s\n' "$exec_line" | sed -n 's/.*--password[[:space:]]*\([^[:space:]]*\).*/\1/p')
                    local stls_domain
                    stls_domain=$(printf '%s\n' "$exec_line" | sed -n 's/.*--tls[[:space:]]*\([^[:space:]]*\).*/\1/p')
                    
                    if [ "$port" = "$(get_snell_port)" ]; then
                        echo -e "\n${GREEN}主用户配置：${RESET}"
                    else
                        echo -e "\n${GREEN}用户配置 (Snell 端口: ${port}):${RESET}"
                    fi
                    
                    if [ -n "$stls_port" ] && [ -n "$stls_password" ] && [ -n "$stls_domain" ]; then
                        echo -e "${YELLOW}Snell 配置：${RESET}"
                        echo -e "  - 端口：${port}"
                        echo -e "  - PSK：${psk}"
                        
                        echo -e "\n${YELLOW}ShadowTLS 配置：${RESET}"
                        echo -e "  - 监听端口：${stls_port}"
                        echo -e "  - 密码：${stls_password}"
                        echo -e "  - SNI：${stls_domain}"
                        echo -e "  - 版本：3"
                        
                        echo -e "\n${GREEN}Surge 配置：${RESET}"
                        local snell_version
                        snell_version=$(get_snell_version)
                        if [ "$snell_version" = "5" ]; then
                            echo -e "Snell v4 + ShadowTLS = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3"
                            echo -e "Snell v5 + ShadowTLS = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 5, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3"
                        else
                            echo -e "Snell + ShadowTLS = snell, ${server_ip}, ${stls_port}, psk = ${psk}, version = 4, reuse = true, tfo = true, shadow-tls-password = ${stls_password}, shadow-tls-sni = ${stls_domain}, shadow-tls-version = 3"
                        fi
                        
                        if stls_service_is_active "shadowtls-snell-${port}"; then
                            echo -e "\n${GREEN}服务状态：正在运行${RESET}"
                            show_port_listeners "$stls_port"
                        else
                            echo -e "\n${RED}服务状态：未运行${RESET}"
                        fi
                    fi
                fi
            done < "$tmp_snell_v"
            rm -f "$tmp_snell_v"
        fi
    fi
    
    if ! $has_config; then
        echo -e "${YELLOW}未找到任何 ShadowTLS 配置${RESET}"
    fi
}

# 新增 ShadowTLS 配置
add_shadowtls_config() {
    echo -e "${CYAN}新增 ShadowTLS 配置...${RESET}"
    
    local has_ss=false
    local has_snell=false
    local has_ss_stls=false
    
    if check_ssrust; then
        has_ss=true
        if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ] || [ -f "/etc/init.d/shadowtls-ss" ]; then
            has_ss_stls=true
        fi
    fi
    
    if check_snell; then
        has_snell=true
    fi
    
    if ! $has_ss && ! $has_snell; then
        echo -e "${RED}未检测到 Shadowsocks Rust 或 Snell，请先安装其中一个${RESET}"
        return 1
    fi
    
    while true; do
        echo -e "\n${YELLOW}请选择要配置的服务：${RESET}"
        if $has_ss && ! $has_ss_stls; then
            echo -e "1. 为 Shadowsocks 配置 ShadowTLS"
        elif $has_ss && $has_ss_stls; then
            echo -e "${GREEN}1. Shadowsocks 已配置 ShadowTLS${RESET}"
        fi
        
        if $has_snell; then
            echo -e "2. 为 Snell 端口配置 ShadowTLS"
        fi
        echo -e "0. 返回上级菜单"
        
        printf "%b" "请选择: "
        read -r choice
        
        case "$choice" in
            0)
                return 0
                ;;
            1)
                if ! $has_ss; then
                    echo -e "${RED}未安装 Shadowsocks${RESET}"
                    continue
                fi
                if $has_ss_stls; then
                    echo -e "${YELLOW}Shadowsocks 已配置 ShadowTLS${RESET}"
                    continue
                fi
                
                local password
                password=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || awk 'BEGIN{srand(); for(i=0;i<16;i++) printf "%c", int(65+rand()*26)}')
                
                printf "%b" "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): "
                read -r tls_domain
                [ -z "$tls_domain" ] && tls_domain="www.microsoft.com"
                
                local ss_listen_port
                while true; do
                    printf "%b" "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): "
                    read -r ss_listen_port
                    
                    ss_listen_port=$(get_available_port "$ss_listen_port")
                    if [ $? -eq 0 ]; then
                        break
                    fi
                    echo -e "${YELLOW}请重新输入端口${RESET}"
                done
                
                echo -e "${GREEN}将使用端口: ${ss_listen_port}${RESET}"
                
                local ss_port
                ss_port=$(get_ssrust_port)
                create_shadowtls_service "ss" "$ss_port" "$ss_listen_port" "$tls_domain" "$password"
                stls_service_enable "shadowtls-ss"
                stls_service_restart "shadowtls-ss"
                open_firewall_port "$ss_listen_port"
                verify_shadowtls_service "shadowtls-ss"
                
                local server_ip
                server_ip=$(get_server_ip)
                local ssrust_password
                local ssrust_method
                ssrust_password=$(get_ssrust_password)
                ssrust_method=$(get_ssrust_method)
                generate_ss_links "${server_ip}" "${ss_listen_port}" "${ssrust_password}" "${ssrust_method}" "${password}" "${tls_domain}" "${ss_port}"
                break
                ;;
            2)
                if ! $has_snell; then
                    echo -e "${RED}未安装 Snell${RESET}"
                    continue
                fi
                
                local password
                password=$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || awk 'BEGIN{srand(); for(i=0;i<16;i++) printf "%c", int(65+rand()*26)}')
                
                printf "%b" "请输入 TLS 伪装域名 (直接回车默认为 www.microsoft.com): "
                read -r tls_domain
                [ -z "$tls_domain" ] && tls_domain="www.microsoft.com"
                
                local user_configs
                user_configs=$(get_all_snell_users)
                if [ -z "$user_configs" ]; then
                    echo -e "${RED}未找到有效的 Snell 用户配置${RESET}"
                    return 1
                fi
                
                echo -e "\n${YELLOW}未配置 ShadowTLS 的 Snell 端口列表：${RESET}"
                local tmp_snell_unconf
                tmp_snell_unconf=$(mktemp 2>/dev/null || echo "/tmp/snell_unconf.$$")
                printf '%s\n' "$user_configs" > "$tmp_snell_unconf"

                local port_list=""
                local port_count=0
                while IFS='|' read -r port psk; do
                    if [ -n "$port" ] && [ ! -f "${SYSTEMD_DIR}/shadowtls-snell-${port}.service" ] && [ ! -f "/etc/init.d/shadowtls-snell-${port}" ]; then
                        port_count=$((port_count + 1))
                        port_list="${port_list} ${port}"
                        if [ "$port" = "$(get_snell_port)" ]; then
                            echo -e "${GREEN}${port_count}. ${port} (主用户)${RESET}"
                        else
                            echo -e "${GREEN}${port_count}. ${port}${RESET}"
                        fi
                    fi
                done < "$tmp_snell_unconf"
                rm -f "$tmp_snell_unconf"
                
                if [ "$port_count" -eq 0 ]; then
                    echo -e "${YELLOW}所有 Snell 端口都已配置 ShadowTLS${RESET}"
                    return 0
                fi
                
                echo -e "\n${YELLOW}请选择要配置的端口：${RESET}"
                echo -e "1-${port_count}. 选择单个端口"
                echo -e "0. 为所有未配置端口配置 ShadowTLS"
                
                printf "%b" "请选择: "
                read -r port_choice
                
                if [ "$port_choice" = "0" ]; then
                    for port in $port_list; do
                        echo -e "\n${YELLOW}为 Snell 端口 ${port} 配置 ShadowTLS${RESET}"
                        local stls_port
                        while true; do
                            printf "%b" "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): "
                            read -r stls_port
                            stls_port=$(get_available_port "$stls_port")
                            [ $? -eq 0 ] && break
                            echo -e "${YELLOW}请重新输入端口${RESET}"
                        done
                        
                        create_shadowtls_service "snell" "$port" "$stls_port" "$tls_domain" "$password"
                        stls_service_enable "shadowtls-snell-${port}"
                        stls_service_restart "shadowtls-snell-${port}"
                        open_firewall_port "$stls_port"
                        verify_shadowtls_service "shadowtls-snell-${port}"
                        
                        local server_ip
                        server_ip=$(get_server_ip)
                        local psk
                        psk=$(grep -E "^psk = " "/etc/snell/users/snell-${port}.conf" 2>/dev/null | sed 's/psk = //' || grep -E "^psk = " "/etc/snell/users/snell-main.conf" 2>/dev/null | sed 's/psk = //')
                        generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${port}"
                    done
                elif is_number "$port_choice" && [ "$port_choice" -ge 1 ] && [ "$port_choice" -le "$port_count" ]; then
                    local selected_port=""
                    local idx=1
                    for p in $port_list; do
                        if [ "$idx" -eq "$port_choice" ]; then
                            selected_port="$p"
                            break
                        fi
                        idx=$((idx + 1))
                    done

                    echo -e "\n${YELLOW}为 Snell 端口 ${selected_port} 配置 ShadowTLS${RESET}"
                    local stls_port
                    while true; do
                        printf "%b" "请输入 ShadowTLS 监听端口 (1-65535，直接回车随机生成): "
                        read -r stls_port
                        stls_port=$(get_available_port "$stls_port")
                        [ $? -eq 0 ] && break
                        echo -e "${YELLOW}请重新输入端口${RESET}"
                    done
                    
                    create_shadowtls_service "snell" "$selected_port" "$stls_port" "$tls_domain" "$password"
                    stls_service_enable "shadowtls-snell-${selected_port}"
                    stls_service_restart "shadowtls-snell-${selected_port}"
                    open_firewall_port "$stls_port"
                    verify_shadowtls_service "shadowtls-snell-${selected_port}"
                    
                    local server_ip
                    server_ip=$(get_server_ip)
                    local psk
                    psk=$(grep -E "^psk = " "/etc/snell/users/snell-${selected_port}.conf" 2>/dev/null | sed 's/psk = //' || grep -E "^psk = " "/etc/snell/users/snell-main.conf" 2>/dev/null | sed 's/psk = //')
                    generate_snell_links "${server_ip}" "${stls_port}" "${psk}" "${password}" "${tls_domain}" "${selected_port}"
                else
                    echo -e "${RED}无效的选择${RESET}"
                    continue
                fi
                break
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
    
    echo -e "\n${GREEN}新增配置完成${RESET}"
}

# 重启 ShadowTLS 服务
restart_shadowtls_services() {
    echo -e "${CYAN}重启 ShadowTLS 服务...${RESET}"
    local has_services=false
    
    # 重启 SS 服务
    if [ -f "${SYSTEMD_DIR}/shadowtls-ss.service" ] || [ -f "/etc/init.d/shadowtls-ss" ]; then
        has_services=true
        echo -e "\n${YELLOW}重启 Shadowsocks 的 ShadowTLS 服务...${RESET}"
        stls_service_restart "shadowtls-ss"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Shadowsocks ShadowTLS 服务重启成功${RESET}"
        else
            echo -e "${RED}Shadowsocks ShadowTLS 服务重启失败${RESET}"
        fi
    fi
    
    # 重启所有 Snell 服务
    local snell_service_files=""
    if [ -d "${SYSTEMD_DIR}" ]; then
        snell_service_files=$(find "${SYSTEMD_DIR}" -name "shadowtls-snell-*.service" 2>/dev/null)
    fi
    if [ -z "$snell_service_files" ] && [ -d "/etc/init.d" ]; then
        snell_service_files=$(ls /etc/init.d/shadowtls-snell-* 2>/dev/null)
    fi

    if [ -n "$snell_service_files" ]; then
        has_services=true
        echo -e "\n${YELLOW}重启 Snell 的 ShadowTLS 服务...${RESET}"
        for service_file in $snell_service_files; do
            [ -f "$service_file" ] || continue
            local service_name
            service_name=$(basename "$service_file" .service)
            echo -e "重启服务: ${service_name} ..."
            stls_service_restart "$service_name"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}${service_name} 重启成功${RESET}"
            else
                echo -e "${RED}${service_name} 重启失败${RESET}"
            fi
        done
    fi
    
    if ! $has_services; then
        echo -e "${RED}未找到任何 ShadowTLS 服务${RESET}"
        return 1
    fi
    
    echo -e "\n${GREEN}所有服务重启完成${RESET}"
}

# 主菜单
main_menu() {
    while true; do
        echo -e "\n${CYAN}ShadowTLS 管理菜单${RESET}"
        echo -e "${YELLOW}1. 安装 ShadowTLS${RESET}"
        echo -e "${YELLOW}2. 卸载 ShadowTLS${RESET}"
        echo -e "${YELLOW}3. 查看配置${RESET}"
        echo -e "${YELLOW}4. 新增配置${RESET}"
        echo -e "${YELLOW}5. 重启服务${RESET}"
        echo -e "${YELLOW}6. 返回上级菜单${RESET}"
        echo -e "${YELLOW}0. 退出${RESET}"
        
        printf "%b" "请选择操作 [0-6]: "
        read -r choice
        
        case "$choice" in
            1)
                install_shadowtls
                ;;
            2)
                uninstall_shadowtls
                ;;
            3)
                view_config
                ;;
            4)
                add_shadowtls_config
                ;;
            5)
                restart_shadowtls_services
                ;;
            6)
                return 0
                ;;
            0)
                exit 0
                ;;
            *)
                echo -e "${RED}无效的选择${RESET}"
                ;;
        esac
    done
}

# 检查root权限
check_root

# 启动主菜单
main_menu "$@"
