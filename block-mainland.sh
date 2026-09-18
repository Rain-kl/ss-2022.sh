#!/bin/sh
set -e

# =========================================
# 作者: jinqians
# 日期: 2025年4月
# 描述: 屏蔽中国大陆连接 Shadowsocks Rust 脚本 (POSIX sh 兼容)
# =========================================

# 版本信息
SCRIPT_VERSION="1.2"

# 脚本路径
SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)
SCRIPT_DIR=$(dirname "${SCRIPT_PATH}")
SCRIPT_NAME=$(basename "$0")
SCRIPT_FULL_PATH="${SCRIPT_PATH}/${SCRIPT_NAME}"

# 配置路径
INSTALL_DIR="/etc/ss-rust"
CONFIG_PATH="/etc/ss-rust/config.json"
IPLIST_DIR="/etc/ss-rust/iprules"
MAINLAND_IP_FILE="${IPLIST_DIR}/mainland_cn.txt"
MMDB_FILE="${IPLIST_DIR}/Country.mmdb"
IPTABLES_RULES="/etc/ss-rust/mainland_cn_rules.sh"
EXTRACT_SCRIPT="${SCRIPT_PATH}/extract-cn-ip-from-mmdb.py"
AUTO_UPDATE_CRON_FILE="/etc/cron.d/block-mainland-auto-update"
BOOT_SERVICE_NAME="block-mainland.service"
BOOT_SERVICE_FILE="/etc/systemd/system/block-mainland.service"
OPENRC_INIT_FILE="/etc/init.d/block-mainland"
AUTO_UPDATE_LOG_FILE="/var/log/block-mainland-update.log"
DAILY_CRON_EXPR="30 4 * * *"
WEEKLY_CRON_EXPR="30 4 * * 1"

# 颜色定义
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
PLAIN="\033[0m"
BOLD="\033[1m"

# 状态提示
INFO="${GREEN}[信息]${PLAIN}"
ERROR="${RED}[错误]${PLAIN}"
WARNING="${YELLOW}[警告]${PLAIN}"
SUCCESS="${GREEN}[成功]${PLAIN}"

# 检查root权限
check_root() {
    if [ "$(id -u 2>/dev/null || echo 1)" -ne 0 ]; then
        printf "%b 此脚本需要root权限运行\n" "${ERROR}"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    printf "%b 检查依赖...\n" "${INFO}"
    
    missing_deps=""
    
    # 检查必需的工具
    for cmd in curl iptables python3; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps="${missing_deps}${missing_deps:+ }$cmd"
        fi
    done
    
    if [ -n "$missing_deps" ]; then
        printf "%b 缺少依赖: %s\n" "${WARNING}" "$missing_deps"
        printf "%b 正在安装依赖...\n" "${INFO}"
        
        if command -v apk >/dev/null 2>&1; then
            apk update && apk add curl iptables ipset python3 py3-pip py3-maxminddb
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update
            # shellcheck disable=SC2086
            apt-get install -y $missing_deps
        elif command -v dnf >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            dnf install -y $missing_deps
        elif command -v yum >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            yum install -y $missing_deps
        elif command -v pacman >/dev/null 2>&1; then
            pacman -Sy --noconfirm curl iptables ipset python python-pip
        elif command -v opkg >/dev/null 2>&1; then
            opkg update
            # shellcheck disable=SC2086
            opkg install $missing_deps
        elif command -v xbps-install >/dev/null 2>&1; then
            # shellcheck disable=SC2086
            xbps-install -Sy $missing_deps
        else
            printf "%b 无法自动安装依赖，请手动安装后重试\n" "${ERROR}"
            exit 1
        fi
    fi
    
    # 检查pip
    printf "%b 检查pip...\n" "${INFO}"
    if ! python3 -m pip --version >/dev/null 2>&1; then
        printf "%b pip未安装，正在安装...\n" "${WARNING}"
        if command -v apk >/dev/null 2>&1; then
            apk add py3-pip >/dev/null 2>&1 || true
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get install -y python3-pip >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y python3-pip >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y python3-pip >/dev/null 2>&1 || true
        elif command -v pacman >/dev/null 2>&1; then
            pacman -S --noconfirm python-pip >/dev/null 2>&1 || true
        fi
    fi
    
    # 检查Python maxminddb库
    printf "%b 检查Python maxminddb库...\n" "${INFO}"
    if ! python3 -c "import maxminddb" >/dev/null 2>&1; then
        printf "%b 缺少Python库: maxminddb\n" "${WARNING}"
        printf "%b 正在安装依赖...\n" "${INFO}"
        
        # 先尝试用系统包管理器安装
        if command -v apk >/dev/null 2>&1; then
            apk add py3-maxminddb >/dev/null 2>&1 || true
        elif command -v apt-get >/dev/null 2>&1; then
            if apt-cache search python3-maxminddb 2>/dev/null | grep -q python3-maxminddb; then
                printf "%b 通过apt安装maxminddb...\n" "${INFO}"
                apt-get install -y python3-maxminddb >/dev/null 2>&1 && printf "%b maxminddb库安装成功\n" "${SUCCESS}" && return 0 || true
            fi
            
            # 否则安装编译依赖然后用pip
            printf "%b 安装编译依赖...\n" "${INFO}"
            apt-get install -y python3-dev build-essential >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            printf "%b 安装编译依赖...\n" "${INFO}"
            dnf install -y python3-devel gcc >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            printf "%b 安装编译依赖...\n" "${INFO}"
            yum install -y python3-devel gcc >/dev/null 2>&1 || true
        elif command -v pacman >/dev/null 2>&1; then
            pacman -S --noconfirm python-maxminddb >/dev/null 2>&1 || true
        fi
        
        # 用pip安装，添加--break-system-packages标志（兼容PEP 668）
        if ! python3 -c "import maxminddb" >/dev/null 2>&1; then
            printf "%b 安装maxminddb库...\n" "${INFO}"
            python3 -m pip install --break-system-packages maxminddb 2>&1 | tail -5 && printf "%b maxminddb库安装成功\n" "${SUCCESS}" || printf "%b maxminddb库安装可能失败，请手动检查Python环境\n" "${WARNING}"
        else
            printf "%b maxminddb库安装成功\n" "${SUCCESS}"
        fi
    fi
    
    printf "%b 依赖检查完成\n" "${SUCCESS}"
}

# 创建必要的目录
create_directories() {
    printf "%b 创建必要的目录...\n" "${INFO}"
    
    if [ ! -d "$INSTALL_DIR" ]; then
        mkdir -p "$INSTALL_DIR"
    fi
    
    if [ ! -d "$IPLIST_DIR" ]; then
        mkdir -p "$IPLIST_DIR"
    fi
    
    printf "%b 目录创建完成\n" "${SUCCESS}"
}

# 检查IP目录是否存在
ensure_ip_dirs() {
    if [ ! -d "$IPLIST_DIR" ]; then
        printf "%b IP列表目录不存在，请先运行选项 1 进行初始化\n" "${ERROR}"
        exit 1
    fi
}

# 下载MaxMind GeoIP2数据库文件
download_maxmind_mmdb() {
    printf "%b 正在下载MaxMind GeoIP2数据库...\n" "${INFO}"
    
    mmdb_url="https://github.com/Hackl0us/GeoIP2-CN/raw/release/Country.mmdb"
    
    printf "%b 从 %s 下载...\n" "${INFO}" "$mmdb_url"
    
    if curl -L -s "$mmdb_url" -o "$MMDB_FILE" 2>/dev/null && [ -s "$MMDB_FILE" ]; then
        file_size=$(du -h "$MMDB_FILE" | cut -f1)
        printf "%b mmdb文件下载成功 (大小: %s)\n" "${SUCCESS}" "$file_size"
        return 0
    else
        printf "%b 无法下载mmdb文件\n" "${ERROR}"
        return 1
    fi
}

# 从MaxMind mmdb文件提取中国IP CIDR
extract_china_ip_from_mmdb() {
    printf "%b 正在从mmdb文件提取中国IP段...\n" "${INFO}"
    
    if [ ! -f "$MMDB_FILE" ]; then
        printf "%b mmdb文件不存在: %s\n" "${ERROR}" "$MMDB_FILE"
        return 1
    fi
    
    if [ ! -f "$EXTRACT_SCRIPT" ]; then
        printf "%b 提取脚本不存在: %s\n" "${ERROR}" "$EXTRACT_SCRIPT"
        return 1
    fi
    
    # 先检查maxminddb库是否真的可用
    if ! python3 -c "import maxminddb" >/dev/null 2>&1; then
        printf "%b maxminddb库不可用，跳过mmdb提取\n" "${ERROR}"
        return 1
    fi
    
    # 运行Python脚本提取CIDR
    output=$(PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 python3 "$EXTRACT_SCRIPT" "$MMDB_FILE" "$MAINLAND_IP_FILE" 2>&1)
    
    if [ -f "$MAINLAND_IP_FILE" ]; then
        ip_count=$(wc -l < "$MAINLAND_IP_FILE" 2>/dev/null || echo 0)
        if [ "$ip_count" -gt 100 ]; then
            printf "%b 已提取 %s 个中国IP CIDR段\n" "${SUCCESS}" "$ip_count"
            return 0
        fi
    fi
    
    printf "%b IP段提取失败或数据不足\n" "${ERROR}"
    printf "%b 详细信息: %s\n" "${INFO}" "$output"
    return 1
}

# 下载中国大陆IP列表（仅使用MaxMind）
download_mainland_ip_list() {
    printf "%b 正在从MaxMind GeoIP2数据库提取中国IP列表...\n" "${INFO}"
    
    # 下载并提取MaxMind mmdb文件
    if download_maxmind_mmdb && extract_china_ip_from_mmdb; then
        return 0
    else
        printf "%b 无法获取MaxMind数据，请检查网络连接或手动下载mmdb文件\n" "${ERROR}"
        return 1
    fi
}

# 检测SS-Rust端口（兼容空格、不同JSON结构）
detect_ss_port() {
    default_port="8388"
    ss_port=""

    if [ ! -f "$CONFIG_PATH" ]; then
        echo "$default_port"
        return 0
    fi

    # 优先用Python解析JSON，避免grep受格式影响
    ss_port=$(python3 - "$CONFIG_PATH" 2>/dev/null << 'PY' || true
import json
import sys

cfg_path = sys.argv[1]

def print_port(value):
    if isinstance(value, int) and 1 <= value <= 65535:
        print(value)
        return True
    if isinstance(value, str) and value.isdigit():
        num = int(value)
        if 1 <= num <= 65535:
            print(num)
            return True
    return False

try:
    with open(cfg_path, "r", encoding="utf-8") as f:
        cfg = json.load(f)
except Exception:
    print("")
    raise SystemExit(0)

# 常见单端口字段
for key in ("server_port", "port", "local_port"):
    if key in cfg and print_port(cfg[key]):
        raise SystemExit(0)

# 部分配置使用 servers 数组
servers = cfg.get("servers")
if isinstance(servers, list):
    for item in servers:
        if isinstance(item, dict) and "server_port" in item and print_port(item["server_port"]):
            raise SystemExit(0)

print("")
PY
)

    # Python解析失败时，回退到grep（支持冒号两侧空格）
    if [ -z "$ss_port" ]; then
        ss_port=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' "$CONFIG_PATH" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
    fi

    case "$ss_port" in
        ''|*[!0-9]*)
            echo "$default_port"
            ;;
        *)
            if [ "$ss_port" -ge 1 ] && [ "$ss_port" -le 65535 ]; then
                echo "$ss_port"
            else
                echo "$default_port"
            fi
            ;;
    esac
}

# 收集所有需要屏蔽的端口
# 主节点端口之外，还必须覆盖多端口节点，以及 ShadowTLS 的监听端口
collect_protected_ports() {
    ports=""

    p=$(detect_ss_port)
    case "$p" in
        ''|*[!0-9]*) ;;
        *) ports="${ports}${ports:+ }${p}" ;;
    esac

    for f in /etc/ss-rust/ports/*.json; do
        [ -f "$f" ] || continue
        p=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -1)
        case "$p" in
            ''|*[!0-9]*) ;;
            *) ports="${ports}${ports:+ }${p}" ;;
        esac
    done

    # systemd shadowtls services
    for svc in /etc/systemd/system/shadowtls-*.service; do
        [ -f "$svc" ] || continue
        p=$(grep -oE -- '--listen [^ ]+' "$svc" 2>/dev/null | head -1 | sed 's/.*://')
        case "$p" in
            ''|*[!0-9]*) ;;
            *) ports="${ports}${ports:+ }${p}" ;;
        esac
    done

    # OpenRC / sysvinit shadowtls services
    for svc in /etc/init.d/shadowtls-*; do
        [ -f "$svc" ] || continue
        p=$(grep -oE -- '--listen [^ ]+' "$svc" 2>/dev/null | head -1 | sed 's/.*://')
        case "$p" in
            ''|*[!0-9]*) ;;
            *) ports="${ports}${ports:+ }${p}" ;;
        esac
    done

    [ -z "$ports" ] && return 0
    # shellcheck disable=SC2086
    printf '%s\n' $ports | sort -un
}

# 删除所有引用 mainland_cn_src 的 INPUT 规则
# 直接从 iptables-save 里解析，而不是按当前端口列表删——否则改过端口后旧规则会永远残留
flush_mainland_rules() {
    guard=0
    while [ $guard -lt 100 ]; do
        rule=$(iptables-save 2>/dev/null | grep -m1 -- "-A INPUT .*--match-set mainland_cn_src src" || true)
        [ -z "$rule" ] && break
        # shellcheck disable=SC2086
        iptables -D INPUT ${rule#-A INPUT } 2>/dev/null || break
        guard=$((guard + 1))
    done
}

# 生成iptables规则
generate_iptables_rules() {
    printf "%b 生成iptables规则...\n" "${INFO}"
    
    if [ ! -f "$MAINLAND_IP_FILE" ]; then
        printf "%b IP列表文件不存在\n" "${ERROR}"
        return 1
    fi
    
    detected_ports=$(collect_protected_ports | tr '\n' ' ')
    if [ -z "$detected_ports" ]; then
        printf "%b 未检测到任何 SS / ShadowTLS 端口，将只使用默认端口\n" "${WARNING}"
    else
        printf "%b 将屏蔽以下端口的大陆来源连接: %s\n" "${INFO}" "$detected_ports"
    fi

    # 规则脚本在**运行时**自行探测端口，这样新增多端口节点或 ShadowTLS 之后，
    # 开机自动恢复也能覆盖到，无需重新生成
    cat > "$IPTABLES_RULES" << 'RULESEOF'
#!/bin/sh
# 中国大陆IP屏蔽规则
# 自动生成，请勿手动修改

set -u

# 运行时探测所有需要保护的端口：主节点 + 多端口节点 + ShadowTLS 入口
collect_ports() {
    ports=""

    if [ -f /etc/ss-rust/config.json ]; then
        p=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' /etc/ss-rust/config.json 2>/dev/null | grep -oE '[0-9]+' | head -1)
        case "${p:-}" in
            ''|*[!0-9]*) ;;
            *) ports="${ports}${ports:+ }${p}" ;;
        esac
    fi

    for f in /etc/ss-rust/ports/*.json; do
        [ -f "$f" ] || continue
        p=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+' | head -1)
        case "${p:-}" in
            ''|*[!0-9]*) ;;
            *) ports="${ports}${ports:+ }${p}" ;;
        esac
    done

    for svc in /etc/systemd/system/shadowtls-*.service /etc/init.d/shadowtls-*; do
        [ -f "$svc" ] || continue
        p=$(grep -oE -- '--listen [^ ]+' "$svc" 2>/dev/null | head -1 | sed 's/.*://')
        case "${p:-}" in
            ''|*[!0-9]*) ;;
            *) ports="${ports}${ports:+ }${p}" ;;
        esac
    done

    if [ -z "$ports" ]; then
        ports="8388"
    fi
    # shellcheck disable=SC2086
    printf '%s\n' $ports | sort -un
}

echo "[信息] 清除旧的屏蔽规则..."
# 按 iptables-save 解析删除，确保改过端口后的旧规则也能清干净
guard=0
while [ $guard -lt 100 ]; do
    rule=$(iptables-save 2>/dev/null | grep -m1 -- "-A INPUT .*--match-set mainland_cn_src src" || true)
    [ -z "$rule" ] && break
    iptables -D INPUT ${rule#-A INPUT } 2>/dev/null || break
    guard=$((guard + 1))
done
ipset destroy mainland_cn_src 2>/dev/null || true

echo "[信息] 创建ipset集合..."
ipset create mainland_cn_src hash:net maxelem 200000

echo "[信息] 导入IP列表..."
/usr/local/bin/block-mainland-import-ips.sh

echo "[信息] 应用iptables规则..."
for port in $(collect_ports); do
    echo "[信息]   屏蔽端口 ${port}"
    iptables -I INPUT -p tcp --dport "$port" -m set --match-set mainland_cn_src src -j DROP
    iptables -I INPUT -p udp --dport "$port" -m set --match-set mainland_cn_src src -j DROP
done

echo "[成功] 规则应用完成"
RULESEOF
    
    chmod +x "$IPTABLES_RULES"
    printf "%b iptables规则生成完成\n" "${SUCCESS}"
}

# 生成IP导入脚本
generate_import_script() {
    printf "%b 生成IP导入脚本...\n" "${INFO}"
    
    import_script="/usr/local/bin/block-mainland-import-ips.sh"
    mkdir -p /usr/local/bin
    
    cat > "$import_script" << 'IMPORTEOF'
#!/bin/sh
# IP导入脚本 - 支持CIDR和纯IP格式

MAINLAND_IP_FILE="__MAINLAND_IP_FILE__"

echo "[信息] 开始导入IP列表..."

local_count=0
local_total=$(wc -l < "$MAINLAND_IP_FILE" 2>/dev/null || echo 0)

while IFS= read -r line; do
    # 跳过空行和注释
    case "$line" in
        \#*|"") continue ;;
    esac
    
    # 清理空白
    line=$(echo "$line" | tr -d ' \t\r')
    [ -z "$line" ] && continue
    
    # 检查是否包含前缀长度标记(/)
    case "$line" in
        */*) ;;
        *) line="${line}/32" ;;
    esac
    
    # 导入到ipset
    if ipset add mainland_cn_src "$line" 2>/dev/null; then
        local_count=$((local_count + 1))
    fi
    
    # 进度显示
    if [ $((local_count % 1000)) -eq 0 ]; then
        echo "[进度] 已导入 $local_count/$local_total ..."
    fi
done < "$MAINLAND_IP_FILE"

if [ "$local_count" -eq 0 ]; then
    echo "[错误] 未导入任何IP段，请检查IP列表内容或格式"
    exit 1
fi

echo "[成功] IP列表导入完成！共导入 $local_count 条IP段"
IMPORTEOF

    sed -i "s|__MAINLAND_IP_FILE__|$MAINLAND_IP_FILE|g" "$import_script"
    
    chmod +x "$import_script"
    printf "%b IP导入脚本生成完成\n" "${SUCCESS}"
}

# 安装ipset
install_ipset() {
    printf "%b 检查ipset...\n" "${INFO}"
    
    if ! command -v ipset >/dev/null 2>&1; then
        printf "%b ipset未安装，正在安装...\n" "${WARNING}"
        
        if command -v apk >/dev/null 2>&1; then
            apk add ipset
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get install -y ipset
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y ipset
        elif command -v yum >/dev/null 2>&1; then
            yum install -y ipset
        elif command -v pacman >/dev/null 2>&1; then
            pacman -S --noconfirm ipset
        elif command -v opkg >/dev/null 2>&1; then
            opkg install ipset
        elif command -v xbps-install >/dev/null 2>&1; then
            xbps-install -Sy ipset
        fi
    fi
    
    printf "%b ipset检查完成\n" "${SUCCESS}"
}

# 检查开机自启服务是否启用
is_boot_service_enabled() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        [ -f "$BOOT_SERVICE_FILE" ] && systemctl is-enabled "$BOOT_SERVICE_NAME" >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        [ -f "$OPENRC_INIT_FILE" ] && rc-status default 2>/dev/null | grep -q "block-mainland"
    elif [ -x "$OPENRC_INIT_FILE" ]; then
        return 0
    else
        return 1
    fi
}

# 安装开机自动恢复服务
install_boot_service() {
    printf "%b 配置开机自动恢复...\n" "${INFO}"

    # 1. systemd
    if [ -d /etc/systemd/system ] || [ -d /run/systemd/system ]; then
        mkdir -p /etc/systemd/system
        cat > "$BOOT_SERVICE_FILE" << EOF
[Unit]
Description=Block mainland China IPs for Shadowsocks
After=network-online.target ss-rust.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh ${IPTABLES_RULES}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            if systemctl enable "$BOOT_SERVICE_NAME" >/dev/null 2>&1; then
                printf "%b 已启用开机自动恢复（%s）\n" "${SUCCESS}" "${BOOT_SERVICE_NAME}"
                return 0
            fi
        fi
    fi

    # 2. OpenRC (Alpine Linux)
    if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        cat > "$OPENRC_INIT_FILE" << EOF
#!/sbin/openrc-run
description="Block mainland China IPs for Shadowsocks"

depend() {
    need net
    after ss-rust
}

start() {
    ebegin "Applying mainland IP blocking rules"
    /bin/sh ${IPTABLES_RULES}
    eend \$?
}

stop() {
    ebegin "Flushing mainland IP blocking rules"
    if [ -x "${SCRIPT_FULL_PATH}" ]; then
        "${SCRIPT_FULL_PATH}" disable >/dev/null 2>&1 || true
    elif [ -x /usr/local/bin/block-mainland.sh ]; then
        /usr/local/bin/block-mainland.sh disable >/dev/null 2>&1 || true
    fi
    eend \$?
}
EOF
        chmod +x "$OPENRC_INIT_FILE"
        if rc-update add block-mainland default >/dev/null 2>&1; then
            printf "%b 已启用开机自动恢复（OpenRC block-mainland）\n" "${SUCCESS}"
            return 0
        fi
    elif [ -d "/etc/init.d" ] && ! [ -d /run/systemd/system ]; then
        # 3. SysVinit / BusyBox
        cat > "$OPENRC_INIT_FILE" << EOF
#!/bin/sh
case "\$1" in
    start)
        echo "Applying mainland IP blocking rules..."
        /bin/sh ${IPTABLES_RULES}
        ;;
    stop)
        echo "Flushing mainland IP blocking rules..."
        if [ -x "${SCRIPT_FULL_PATH}" ]; then
            "${SCRIPT_FULL_PATH}" disable >/dev/null 2>&1 || true
        elif [ -x /usr/local/bin/block-mainland.sh ]; then
            /usr/local/bin/block-mainland.sh disable >/dev/null 2>&1 || true
        fi
        ;;
    restart)
        "\$0" stop
        "\$0" start
        ;;
    status)
        if iptables -S INPUT 2>/dev/null | grep -q "mainland_cn_src"; then
            echo "Block mainland rules are active."
        else
            echo "Block mainland rules are not active."
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
EOF
        chmod +x "$OPENRC_INIT_FILE"
        printf "%b 已安装开机脚本（%s）\n" "${SUCCESS}" "$OPENRC_INIT_FILE"
        return 0
    fi

    printf "%b 开机自动恢复服务配置失败，重启后需手动执行: sh %s\n" "${WARNING}" "$IPTABLES_RULES"
}

# 移除开机自动恢复服务
remove_boot_service() {
    if [ -f "$BOOT_SERVICE_FILE" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable "$BOOT_SERVICE_NAME" >/dev/null 2>&1 || true
        fi
        rm -f "$BOOT_SERVICE_FILE"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl daemon-reload >/dev/null 2>&1 || true
        fi
    fi
    if [ -f "$OPENRC_INIT_FILE" ]; then
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del block-mainland default >/dev/null 2>&1 || true
        fi
        rm -f "$OPENRC_INIT_FILE"
    fi
}

# 启用屏蔽规则
enable_blocking() {
    printf "%b 启用屏蔽规则...\n" "${INFO}"
    
    # 安装ipset
    install_ipset
    
    # 生成并执行规则
    if [ ! -f "$IPTABLES_RULES" ]; then
        printf "%b 规则文件不存在: %s\n" "${ERROR}" "$IPTABLES_RULES"
        return 1
    fi
    if ! sh "$IPTABLES_RULES"; then
        printf "%b 规则应用失败\n" "${ERROR}"
        return 1
    fi
    
    # 保存iptables规则（部分系统装了 netfilter-persistent 会用到；目录可能不存在）
    if command -v iptables-save >/dev/null 2>&1; then
        mkdir -p /etc/iptables 2>/dev/null || true
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi

    # 关键：重启后 ipset 会清空，必须靠开机服务重建
    install_boot_service
    
    printf "%b 屏蔽规则已启用\n" "${SUCCESS}"
}

# 禁用屏蔽规则
disable_blocking() {
    printf "%b 禁用屏蔽规则...\n" "${INFO}"

    # 删除所有引用 mainland_cn_src 的规则（不依赖当前端口，改过端口的旧规则也能清掉）
    flush_mainland_rules
    
    # 删除ipset
    ipset destroy mainland_cn_src 2>/dev/null || true

    # 取消开机自动恢复，否则重启后又会被重新下上
    remove_boot_service

    # 同步已保存的规则，避免 netfilter-persistent 在重启时恢复旧规则
    if command -v iptables-save >/dev/null 2>&1 && [ -f /etc/iptables/rules.v4 ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    
    printf "%b 屏蔽规则已禁用\n" "${SUCCESS}"
}

# 查看规则状态
show_status() {
    protected_ports=$(collect_protected_ports | tr '\n' ' ')

    printf "%b═══════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    printf "%b    中国大陆屏蔽规则状态%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    printf "%b═══════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    printf "%b受保护端口:%b %s\n" "${BOLD}" "${PLAIN}" "${protected_ports:-无}"
    
    echo ""
    printf "%bIP列表文件:%b\n" "${BOLD}" "${PLAIN}"
    if [ -f "$MAINLAND_IP_FILE" ]; then
        ip_count=$(wc -l < "$MAINLAND_IP_FILE" 2>/dev/null || echo 0)
        file_sz=$(du -h "$MAINLAND_IP_FILE" 2>/dev/null | cut -f1)
        printf "  %b✓%b 存在 (共 %s 个CIDR段)\n" "${GREEN}" "${PLAIN}" "$ip_count"
        printf "  文件路径: %s\n" "$MAINLAND_IP_FILE"
        printf "  文件大小: %s\n" "$file_sz"
    else
        printf "  %b✗%b 不存在\n" "${RED}" "${PLAIN}"
    fi
    
    echo ""
    printf "%bipset状态:%b\n" "${BOLD}" "${PLAIN}"
    if ipset list mainland_cn_src >/dev/null 2>&1; then
        ip_set_count=$(ipset save mainland_cn_src 2>/dev/null | grep "add" | wc -l)
        printf "  %b✓%b 已创建 (共 %s 个IP段)\n" "${GREEN}" "${PLAIN}" "$ip_set_count"
    else
        printf "  %b✗%b 未创建\n" "${RED}" "${PLAIN}"
    fi
    
    echo ""
    printf "%biptables规则:%b\n" "${BOLD}" "${PLAIN}"
    rule_ports=$(iptables -S INPUT 2>/dev/null | grep -- "--match-set mainland_cn_src src" | grep -oE '\-\-[d]port [0-9]+' | awk '{print $2}' | sort -un | tr '\n' ' ')
    if [ -n "$rule_ports" ]; then
        printf "  %b✓%b 已启用 (生效端口: %s)\n" "${GREEN}" "${PLAIN}" "${rule_ports}"
        # 有节点端口没被覆盖时明确提示，否则用户会以为已经全屏蔽了
        missing=""
        for pt in $(collect_protected_ports); do
            case " $rule_ports " in
                *" $pt "*) ;;
                *) missing="${missing}${pt} " ;;
            esac
        done
        if [ -n "$missing" ]; then
            printf "  %b!%b 以下端口尚未纳入屏蔽: %s\n" "${YELLOW}" "${PLAIN}" "${missing}"
            printf "  %b!%b 请重新执行\"初始化并启用屏蔽\"以覆盖新增节点\n" "${YELLOW}" "${PLAIN}"
        fi
    elif iptables -S INPUT 2>/dev/null | grep -q "mainland_cn_src"; then
        printf "  %b✓%b 已启用\n" "${GREEN}" "${PLAIN}"
    else
        printf "  %b✗%b 未启用\n" "${RED}" "${PLAIN}"
    fi

    echo ""
    printf "%b开机自动恢复:%b\n" "${BOLD}" "${PLAIN}"
    if is_boot_service_enabled; then
        printf "  %b✓%b 已启用\n" "${GREEN}" "${PLAIN}"
    else
        printf "  %b✗%b 未启用 — 服务器重启后屏蔽规则将失效\n" "${RED}" "${PLAIN}"
    fi
    
    echo ""
    printf "%b═══════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"
}

# 更新IP列表
update_ip_list() {
    printf "%b 更新IP列表...\n" "${INFO}"
    
    # 禁用旧规则
    disable_blocking
    
    # 下载新列表
    download_mainland_ip_list || {
        printf "%b IP列表更新失败\n" "${ERROR}"
        return 1
    }
    
    # 重新生成规则和脚本
    generate_iptables_rules
    generate_import_script
    
    # 启用新规则
    enable_blocking
    
    printf "%b IP列表更新完成\n" "${SUCCESS}"
}

# 获取用于定时任务调用的脚本路径
get_script_exec_path() {
    if [ -x "/usr/local/bin/block-mainland.sh" ]; then
        echo "/usr/local/bin/block-mainland.sh"
    else
        echo "$SCRIPT_FULL_PATH"
    fi
}

# 校验cron表达式（仅校验字段数）
is_valid_cron_expr() {
    expr="$1"
    expr=$(echo "$expr" | awk '{$1=$1; print}')

    if [ -z "$expr" ]; then
        return 1
    fi

    [ "$(echo "$expr" | awk '{print NF}')" -eq 5 ]
}

# 规范化输入的计划类型
normalize_schedule_input() {
    input="$1"

    case "$input" in
        daily)
            echo "$DAILY_CRON_EXPR"
            ;;
        weekly)
            echo "$WEEKLY_CRON_EXPR"
            ;;
        *)
            echo "$input"
            ;;
    esac
}

# 尝试确保系统的cron服务可用
ensure_cron_service() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl list-unit-files 2>/dev/null | grep -q '^cron\.service'; then
            systemctl enable --now cron >/dev/null 2>&1 || true
        elif systemctl list-unit-files 2>/dev/null | grep -q '^crond\.service'; then
            systemctl enable --now crond >/dev/null 2>&1 || true
        fi
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
        rc-service crond start >/dev/null 2>&1 || true
        rc-update add crond default >/dev/null 2>&1 || true
    fi
}

# 开启定时更新
enable_auto_update() {
    schedule_input="$1"
    cron_expr=""

    if [ -n "$schedule_input" ]; then
        cron_expr=$(normalize_schedule_input "$schedule_input")
        if ! is_valid_cron_expr "$cron_expr"; then
            printf "%b 无效的cron表达式: %s\n" "${ERROR}" "$schedule_input"
            printf "%b 示例: '30 4 * * *'\n" "${INFO}"
            return 1
        fi
    else
        printf "%b 请选择定时更新频率:\n" "${INFO}"
        echo "  1) 每日 04:30"
        echo "  2) 每周一 04:30"
        echo "  3) 自定义 cron 表达式"
        printf "请选择 [1-3] (默认: 1): "
        read -r schedule_choice
        [ -z "$schedule_choice" ] && schedule_choice="1"

        case "$schedule_choice" in
            1)
                cron_expr="$DAILY_CRON_EXPR"
                ;;
            2)
                cron_expr="$WEEKLY_CRON_EXPR"
                ;;
            3)
                printf "请输入 cron 表达式(5段，如: 30 4 * * *): "
                read -r custom_expr
                if ! is_valid_cron_expr "$custom_expr"; then
                    printf "%b cron表达式格式无效\n" "${ERROR}"
                    return 1
                fi
                cron_expr="$custom_expr"
                ;;
            *)
                printf "%b 无效选项\n" "${ERROR}"
                return 1
                ;;
        esac
    fi

    ensure_cron_service

    script_exec_path=$(get_script_exec_path)

    touch "$AUTO_UPDATE_LOG_FILE"

    if [ -d "/etc/cron.d" ]; then
        cat > "$AUTO_UPDATE_CRON_FILE" << EOF
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$cron_expr root PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 sh $script_exec_path update >> $AUTO_UPDATE_LOG_FILE 2>&1
EOF
        chmod 644 "$AUTO_UPDATE_CRON_FILE"
    elif command -v crontab >/dev/null 2>&1; then
        (crontab -l 2>/dev/null | grep -v 'block-mainland.*update' || true; echo "$cron_expr PYTHONIOENCODING=UTF-8 LC_ALL=C.UTF-8 LANG=C.UTF-8 sh $script_exec_path update >> $AUTO_UPDATE_LOG_FILE 2>&1 # block-mainland-auto-update") | crontab -
    fi

    printf "%b 定时更新已开启\n" "${SUCCESS}"
    printf "%b 更新频率: %s\n" "${INFO}" "$cron_expr"
    printf "%b 日志文件: %s\n" "${INFO}" "$AUTO_UPDATE_LOG_FILE"
}

# 关闭定时更新
disable_auto_update() {
    removed=false
    if [ -f "$AUTO_UPDATE_CRON_FILE" ]; then
        rm -f "$AUTO_UPDATE_CRON_FILE"
        removed=true
    fi
    if command -v crontab >/dev/null 2>&1; then
        if crontab -l 2>/dev/null | grep -q 'block-mainland.*update'; then
            (crontab -l 2>/dev/null | grep -v 'block-mainland.*update' || true) | crontab -
            removed=true
        fi
    fi

    if [ "$removed" = "true" ]; then
        printf "%b 定时更新已关闭\n" "${SUCCESS}"
    else
        printf "%b 定时更新未启用\n" "${WARNING}"
    fi
}

# 查看定时更新状态
show_auto_update_status() {
    printf "%b═══════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    printf "%b      定时更新任务状态%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    printf "%b═══════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"

    cron_line=""
    cron_expr=""
    if [ -f "$AUTO_UPDATE_CRON_FILE" ]; then
        cron_line=$(grep -vE '^(#|SHELL=|PATH=|$)' "$AUTO_UPDATE_CRON_FILE" | head -1)
        cron_expr=$(echo "$cron_line" | awk '{print $1" "$2" "$3" "$4" "$5}')

        printf "%b✓%b 已启用\n" "${GREEN}" "${PLAIN}"
        printf "  调度表达式: %s\n" "$cron_expr"
        printf "  任务文件: %s\n" "$AUTO_UPDATE_CRON_FILE"
    elif command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'block-mainland.*update'; then
        cron_line=$(crontab -l 2>/dev/null | grep 'block-mainland.*update' | head -1)
        cron_expr=$(echo "$cron_line" | awk '{print $1" "$2" "$3" "$4" "$5}')

        printf "%b✓%b 已启用 (crontab)\n" "${GREEN}" "${PLAIN}"
        printf "  调度表达式: %s\n" "$cron_expr"
    else
        printf "%b✗%b 未启用\n" "${RED}" "${PLAIN}"
    fi

    if [ -f "$AUTO_UPDATE_LOG_FILE" ]; then
        log_sz=$(du -h "$AUTO_UPDATE_LOG_FILE" 2>/dev/null | cut -f1)
        printf "  日志文件: %s\n" "$AUTO_UPDATE_LOG_FILE"
        printf "  日志大小: %s\n" "$log_sz"
    fi

    printf "%b═══════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"
}

# 显示菜单
show_menu() {
    echo ""
    printf "%b════════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    printf "%b  Shadowsocks Rust - 中国大陆屏蔽%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    printf "%b════════════════════════════════════%b\n" "${BLUE}${BOLD}" "${PLAIN}"
    echo ""
    printf "  %b1.%b 下载IP列表并启用屏蔽\n" "${BOLD}" "${PLAIN}"
    printf "  %b2.%b 启用屏蔽规则\n" "${BOLD}" "${PLAIN}"
    printf "  %b3.%b 禁用屏蔽规则\n" "${BOLD}" "${PLAIN}"
    printf "  %b4.%b 更新IP列表\n" "${BOLD}" "${PLAIN}"
    printf "  %b5.%b 查看规则状态\n" "${BOLD}" "${PLAIN}"
    printf "  %b6.%b 开启定时更新\n" "${BOLD}" "${PLAIN}"
    printf "  %b7.%b 关闭定时更新\n" "${BOLD}" "${PLAIN}"
    printf "  %b8.%b 查看定时更新状态\n" "${BOLD}" "${PLAIN}"

    printf "  %b0.%b 退出\n" "${BOLD}" "${PLAIN}"
    echo ""
}

# 主函数
main() {
    check_root
    
    # 如果有参数，直接执行相应操作
    if [ $# -gt 0 ]; then
        case "$1" in
            enable)
                check_dependencies
                create_directories
                download_mainland_ip_list
                generate_iptables_rules
                generate_import_script
                enable_blocking
                show_status
                ;;
            disable)
                disable_blocking
                show_status
                ;;
            update)
                check_dependencies
                update_ip_list
                show_status
                ;;
            auto-update-enable)
                check_dependencies
                create_directories
                enable_auto_update "$2"
                show_auto_update_status
                ;;
            auto-update-disable)
                disable_auto_update
                show_auto_update_status
                ;;
            auto-update-status)
                show_auto_update_status
                ;;
            status)
                show_status
                ;;
            *)
                echo "用法: $SCRIPT_NAME [enable|disable|update|status|auto-update-enable [daily|weekly|\"cron\"]|auto-update-disable|auto-update-status]"
                exit 1
                ;;
        esac
        return 0
    fi
    
    # 交互式菜单
    while true; do
        show_menu
        printf "请选择操作 [0-8]: "
        read -r choice
        
        case "$choice" in
            1)
                check_dependencies
                create_directories
                if download_mainland_ip_list; then
                    generate_iptables_rules
                    generate_import_script
                    enable_blocking
                    show_status
                fi
                ;;
            2)
                ensure_ip_dirs
                check_dependencies
                enable_blocking
                show_status
                ;;
            3)
                disable_blocking
                show_status
                ;;
            4)
                ensure_ip_dirs
                check_dependencies
                update_ip_list
                ;;
            5)
                show_status
                ;;
            6)
                check_dependencies
                create_directories
                enable_auto_update
                show_auto_update_status
                ;;
            7)
                disable_auto_update
                show_auto_update_status
                ;;
            8)
                show_auto_update_status
                ;;
            0)
                printf "%b 退出脚本\n" "${INFO}"
                exit 0
                ;;
            *)
                printf "%b 无效的选择\n" "${ERROR}"
                ;;
        esac
        
        printf "按 Enter 键继续..."
        read -r _dummy
    done
}

# 启动主函数
main "$@"
