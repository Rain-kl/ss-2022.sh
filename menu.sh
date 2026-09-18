#!/bin/sh
# =========================================
# 作者: jinqians
# 网站：jinqians.com
# 描述: 统一管理脚本（支持 POSIX sh、BusyBox、Alpine、OpenWrt 及各类 Linux 发行版）
# =========================================

# 定义颜色代码
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RESET='\033[0m'

# 当前版本号
current_version="4.4"

# systemd 服务目录
SYSTEMD_DIR="/etc/systemd/system"

# 中国大陆屏蔽脚本仓库地址
MAINLAND_BLOCK_URL="https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/block-mainland.sh"
MAINLAND_EXTRACT_URL="https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/extract-cn-ip-from-mmdb.py"
MAINLAND_SCRIPT_DIR="/usr/local/share/ss-2022"

# 检查是否以 root 权限运行
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}请以 root 权限运行此脚本${RESET}"
        exit 1
    fi
}

# 检查并安装基础网络下载工具
check_dependencies() {
    if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}未检测到 curl 或 wget，正在尝试安装...${RESET}"
    if command -v apk >/dev/null 2>&1; then
        apk update && apk add --no-cache curl wget
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y curl wget
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm curl wget
    elif command -v opkg >/dev/null 2>&1; then
        opkg update && opkg install curl wget-ssl
    elif command -v xbps-install >/dev/null 2>&1; then
        xbps-install -Sy curl wget
    else
        echo -e "${RED}未支持的包管理器，请手动安装 curl 或 wget${RESET}"
        exit 1
    fi
}

# 安装全局命令
install_global_command() {
    # 如果已在 /usr/local/bin 或系统中存在 menu 命令，则跳过重复下载
    if [ -f "/usr/local/bin/menu" ] || [ -f "/usr/bin/menu" ]; then
        return 0
    fi

    local target_dir="/usr/local/bin"
    [ -d "$target_dir" ] || target_dir="/usr/bin"

    local current_script
    current_script=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    if [ -f "$current_script" ]; then
        cp "$current_script" "${target_dir}/menu.sh" 2>/dev/null || true
        chmod +x "${target_dir}/menu.sh" 2>/dev/null || true
        ln -sf "${target_dir}/menu.sh" "${target_dir}/menu" 2>/dev/null || true
    fi
}

# 获取 CPU 核心数 (兼容 BusyBox、procinfo、nproc)
get_cpu_cores() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif [ -f /proc/cpuinfo ]; then
        local cores
        cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
        echo "${cores:-1}"
    else
        echo 1
    fi
}

# 获取指定进程的物理内存占用 (kB) (读取 /proc/$pid/status，跨所有 Linux/Busybox 100% 兼容)
get_pid_rss_kb() {
    local pid="$1"
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/${pid}/status" ]; then
        awk '/VmRSS:/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

# 获取指定进程的 CPU 使用率（基于 top 或 ps，配合 awk 运算）
get_cpu_usage() {
    local pid=$1
    local cpu_usage=0
    local cpu_cores
    cpu_cores=$(get_cpu_cores)

    if [ -n "$pid" ] && [ "$pid" != "0" ]; then
        # 优先尝使用标准 top
        cpu_usage=$(top -b -n 2 -d 0.2 -p "$pid" 2>/dev/null | tail -n 1 | awk '{print $9}')
        if [ -z "$cpu_usage" ] || [ "$cpu_usage" = "$pid" ]; then
            cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo 0)
        fi
        [ -z "$cpu_usage" ] && cpu_usage=0
        cpu_usage=$(awk -v u="$cpu_usage" -v c="$cpu_cores" 'BEGIN {if (c+0==0) print "0.00"; else printf "%.2f", u/c}')
    fi
    echo "${cpu_usage:-0.00}"
}

# 检查服务是否正在运行（通用兼容 systemd、OpenRC、SysVinit 与进程检查）
service_is_active() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl is-active "$svc" >/dev/null 2>&1
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" status >/dev/null 2>&1
    elif [ -f "/var/run/${svc}.pid" ] || [ -f "/run/${svc}.pid" ]; then
        local pid
        pid=$(cat "/var/run/${svc}.pid" 2>/dev/null || cat "/run/${svc}.pid" 2>/dev/null)
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
    elif [ -f "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" status >/dev/null 2>&1
    else
        case "$svc" in
            *ss-rust*|*ss*) pgrep -x ss-rust >/dev/null 2>&1 || pidof ss-rust >/dev/null 2>&1 ;;
            *shadowtls*) pgrep -x shadow-tls >/dev/null 2>&1 || pidof shadow-tls >/dev/null 2>&1 ;;
            *snell*) pgrep -x snell-server >/dev/null 2>&1 || pidof snell-server >/dev/null 2>&1 ;;
            *) return 1 ;;
        esac
    fi
}

# 获取服务的主 PID
service_main_pid() {
    local svc="$1"
    local pid=""
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        pid=$(systemctl show -p MainPID "$svc" 2>/dev/null | cut -d'=' -f2)
    fi
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        if [ -f "/var/run/${svc}.pid" ]; then
            pid=$(cat "/var/run/${svc}.pid" 2>/dev/null)
        elif [ -f "/run/${svc}.pid" ]; then
            pid=$(cat "/run/${svc}.pid" 2>/dev/null)
        fi
    fi
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        case "$svc" in
            *ss-rust*|*ss*) pid=$(pgrep -x ss-rust 2>/dev/null | head -n 1) ;;
            *shadowtls*) pid=$(pgrep -x shadow-tls 2>/dev/null | head -n 1) ;;
            *snell*) pid=$(pgrep -x snell-server 2>/dev/null | head -n 1) ;;
        esac
    fi
    echo "${pid:-0}"
}

# 停止服务
service_stop() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" stop 2>/dev/null || true
        rc-update del "$svc" default 2>/dev/null || true
    elif [ -f "/etc/init.d/${svc}" ]; then
        "/etc/init.d/${svc}" stop 2>/dev/null || true
    fi
}

# 检查服务状态并显示
check_and_show_status() {
    local cpu_cores
    cpu_cores=$(get_cpu_cores)

    echo -e "\n${CYAN}=== 服务状态检查 ===${RESET}"
    echo -e "${CYAN}系统 CPU 核心数：${cpu_cores}${RESET}"

    # 1. 检查 Snell 状态
    if command -v snell-server >/dev/null 2>&1; then
        local user_count=0
        local running_count=0
        local total_snell_memory=0
        local total_snell_cpu="0.00"

        # 检查主服务状态
        user_count=$((user_count + 1))
        if service_is_active snell; then
            running_count=$((running_count + 1))
            local main_pid
            main_pid=$(service_main_pid snell)
            if [ -n "$main_pid" ] && [ "$main_pid" != "0" ]; then
                local mem
                mem=$(get_pid_rss_kb "$main_pid")
                local cpu
                cpu=$(get_cpu_usage "$main_pid")
                total_snell_memory=$((total_snell_memory + mem))
                total_snell_cpu=$(awk -v t="$total_snell_cpu" -v c="$cpu" 'BEGIN {printf "%.2f", t+c}')
            fi
        fi

        # 检查多用户状态
        if [ -d "/etc/snell/users" ]; then
            for user_conf in /etc/snell/users/*; do
                [ -f "$user_conf" ] || continue
                case "$user_conf" in
                    *snell-main.conf) continue ;;
                esac
                local port
                port=$(grep -E '^listen' "$user_conf" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
                if [ -n "$port" ]; then
                    user_count=$((user_count + 1))
                    if service_is_active "snell-${port}"; then
                        running_count=$((running_count + 1))
                        local user_pid
                        user_pid=$(service_main_pid "snell-${port}")
                        if [ -n "$user_pid" ] && [ "$user_pid" != "0" ]; then
                            local mem
                            mem=$(get_pid_rss_kb "$user_pid")
                            local cpu
                            cpu=$(get_cpu_usage "$user_pid")
                            total_snell_memory=$((total_snell_memory + mem))
                            total_snell_cpu=$(awk -v t="$total_snell_cpu" -v c="$cpu" 'BEGIN {printf "%.2f", t+c}')
                        fi
                    fi
                fi
            done
        fi

        local total_snell_memory_mb
        total_snell_memory_mb=$(awk -v m="$total_snell_memory" 'BEGIN {printf "%.2f", m/1024}')
        printf "${GREEN}Snell 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：%d/%d${RESET}\n" "${total_snell_cpu:-0.00}" "${total_snell_memory_mb:-0.00}" "$running_count" "$user_count"
    else
        echo -e "${YELLOW}Snell 未安装${RESET}"
    fi

    # 2. 检查 SS-2022 状态
    if [ -e "/usr/local/bin/ss-rust" ]; then
        local ss_memory=0
        local ss_cpu="0.00"
        local ss_running=0

        if service_is_active ss-rust; then
            ss_running=1
            local ss_pid
            ss_pid=$(service_main_pid ss-rust)
            if [ -n "$ss_pid" ] && [ "$ss_pid" != "0" ]; then
                ss_memory=$(get_pid_rss_kb "$ss_pid")
                ss_cpu=$(get_cpu_usage "$ss_pid")
            fi
        fi

        local ss_memory_mb
        ss_memory_mb=$(awk -v m="$ss_memory" 'BEGIN {printf "%.2f", m/1024}')
        printf "${GREEN}SS-2022 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：%d/1${RESET}\n" "$ss_cpu" "$ss_memory_mb" "$ss_running"
    else
        echo -e "${YELLOW}SS-2022 未安装${RESET}"
    fi

    # 3. 检查 ShadowTLS 状态
    local stls_services=""
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        stls_services=$(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep '^shadowtls-')
    fi
    if [ -z "$stls_services" ] && [ -d "${SYSTEMD_DIR}" ]; then
        stls_services=$(ls "${SYSTEMD_DIR}"/shadowtls-*.service 2>/dev/null | while read -r f; do basename "$f" .service; done)
    fi
    if [ -z "$stls_services" ] && [ -d "/etc/init.d" ]; then
        stls_services=$(ls /etc/init.d/shadowtls-* 2>/dev/null | while read -r f; do basename "$f"; done)
    fi

    if [ -n "$stls_services" ]; then
        local stls_total=0
        local stls_running=0
        local total_stls_memory=0
        local total_stls_cpu="0.00"

        for service in $stls_services; do
            stls_total=$((stls_total + 1))
            if service_is_active "$service"; then
                stls_running=$((stls_running + 1))
                local stls_pid
                stls_pid=$(service_main_pid "$service")
                if [ -n "$stls_pid" ] && [ "$stls_pid" != "0" ]; then
                    local mem
                    mem=$(get_pid_rss_kb "$stls_pid")
                    local cpu
                    cpu=$(get_cpu_usage "$stls_pid")
                    total_stls_memory=$((total_stls_memory + mem))
                    total_stls_cpu=$(awk -v t="$total_stls_cpu" -v c="$cpu" 'BEGIN {printf "%.2f", t+c}')
                fi
            fi
        done

        if [ "$stls_total" -gt 0 ]; then
            local total_stls_memory_mb
            total_stls_memory_mb=$(awk -v m="$total_stls_memory" 'BEGIN {printf "%.2f", m/1024}')
            printf "${GREEN}ShadowTLS 已安装${RESET}  ${YELLOW}CPU：%.2f%% (每核)${RESET}  ${YELLOW}内存：%.2f MB${RESET}  ${GREEN}运行中：%d/%d${RESET}\n" "$total_stls_cpu" "$total_stls_memory_mb" "$stls_running" "$stls_total"
        else
            echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
        fi
    else
        echo -e "${YELLOW}ShadowTLS 未安装${RESET}"
    fi

    echo -e "${CYAN}====================${RESET}\n"
}

# 更新脚本
update_script() {
    echo -e "${CYAN}正在检查脚本更新...${RESET}"
    local tmp_script
    tmp_script=$(mktemp 2>/dev/null || echo "/tmp/menu.sh.$$")

    local update_url="https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/menu.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$update_url" -o "$tmp_script" 2>/dev/null
    else
        wget -qO "$tmp_script" "$update_url" 2>/dev/null
    fi

    if [ -s "$tmp_script" ]; then
        local new_version
        new_version=$(grep 'current_version=' "$tmp_script" | head -n 1 | cut -d'"' -f2)
        if [ -z "$new_version" ]; then
            echo -e "${RED}无法获取新版本信息${RESET}"
            rm -f "$tmp_script"
            return 1
        fi

        echo -e "${YELLOW}当前版本：${current_version}${RESET}"
        echo -e "${YELLOW}最新版本：${new_version}${RESET}"

        if [ "$new_version" != "$current_version" ]; then
            printf "%b" "${CYAN}是否更新到新版本？[y/N]: ${RESET}"
            read -r choice
            if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
                local script_path
                script_path=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
                cp "$script_path" "${script_path}.backup" 2>/dev/null || true
                mv "$tmp_script" "$script_path"
                chmod +x "$script_path"
                echo -e "${GREEN}脚本已更新到最新版本！${RESET}"
                echo -e "${CYAN}请重新运行脚本以使用新版本${RESET}"
                exit 0
            else
                echo -e "${YELLOW}已取消更新${RESET}"
                rm -f "$tmp_script"
            fi
        else
            echo -e "${GREEN}当前已是最新版本${RESET}"
            rm -f "$tmp_script"
        fi
    else
        echo -e "${RED}下载新版本失败，请检查网络连接${RESET}"
        rm -f "$tmp_script"
    fi
}

# 统一运行远程或本地脚本的 POSIX 兼容函数（不依赖 bash 或 <(...)）
run_script_module() {
    local script_name="$1"
    local remote_url="$2"

    # 优先查找当前脚本所在目录的本地同名文件
    local script_dir
    script_dir=$(dirname "$0")
    if [ -f "${script_dir}/${script_name}" ]; then
        sh "${script_dir}/${script_name}"
        return $?
    fi

    # 查找 /usr/local/bin
    if [ -f "/usr/local/bin/${script_name}" ]; then
        sh "/usr/local/bin/${script_name}"
        return $?
    fi

    # 临时拉取并执行
    echo -e "${CYAN}正在获取 ${script_name}...${RESET}"
    local tmp_file
    tmp_file=$(mktemp 2>/dev/null || echo "/tmp/${script_name}.$$")

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$remote_url" -o "$tmp_file" 2>/dev/null
    else
        wget -qO "$tmp_file" "$remote_url" 2>/dev/null
    fi

    if [ -s "$tmp_file" ]; then
        chmod +x "$tmp_file"
        sh "$tmp_file"
        local ret=$?
        rm -f "$tmp_file"
        return $ret
    else
        rm -f "$tmp_file"
        echo -e "${RED}下载 ${script_name} 失败，请检查网络连接${RESET}"
        return 1
    fi
}

# 安装/管理 Snell
manage_snell() {
    run_script_module "snell.sh" "https://raw.githubusercontent.com/jinqians/snell.sh/main/snell.sh"
}

# 安装/管理 SS-2022
manage_ss_rust() {
    run_script_module "ss-2022.sh" "https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/ss-2022.sh"
}

# 安装/管理 ShadowTLS
manage_shadowtls() {
    run_script_module "shadowtls.sh" "https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/shadowtls.sh"
}

# 管理中国大陆IP屏蔽
manage_mainland_block() {
    local script_dir
    script_dir=$(dirname "$0")
    if [ -f "${script_dir}/block-mainland.sh" ]; then
        sh "${script_dir}/block-mainland.sh"
        return $?
    fi

    echo -e "${CYAN}正在从仓库获取大陆IP屏蔽脚本...${RESET}"
    mkdir -p "${MAINLAND_SCRIPT_DIR}"

    local dl_cmd="curl -fsSL"
    if ! command -v curl >/dev/null 2>&1; then
        dl_cmd="wget -qO-"
    fi

    if ! $dl_cmd "${MAINLAND_BLOCK_URL}" > "${MAINLAND_SCRIPT_DIR}/block-mainland.sh" 2>/dev/null; then
        echo -e "${RED}下载 block-mainland.sh 失败${RESET}"
        return 1
    fi

    if ! $dl_cmd "${MAINLAND_EXTRACT_URL}" > "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py" 2>/dev/null; then
        echo -e "${RED}下载 extract-cn-ip-from-mmdb.py 失败${RESET}"
        return 1
    fi

    chmod +x "${MAINLAND_SCRIPT_DIR}/block-mainland.sh" "${MAINLAND_SCRIPT_DIR}/extract-cn-ip-from-mmdb.py"
    PYTHONIOENCODING=UTF-8 sh "${MAINLAND_SCRIPT_DIR}/block-mainland.sh"
}

# 安装/管理 VLESS Reality（引导至 PSM）
manage_vless() {
    echo -e "${CYAN}VLESS Reality 的安装管理已由 PSM 提供，正在启动 PSM...${RESET}"
    local tmp_psm
    tmp_psm=$(mktemp 2>/dev/null || echo "/tmp/psm.$$")
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL https://psm.jinqians.com -o "$tmp_psm" 2>/dev/null
    else
        wget -qO "$tmp_psm" https://psm.jinqians.com 2>/dev/null
    fi

    if [ -s "$tmp_psm" ]; then
        sh "$tmp_psm" || true
        rm -f "$tmp_psm"
    else
        rm -f "$tmp_psm"
        echo -e "${RED}PSM 启动失败，请检查网络连接${RESET}"
        return 1
    fi
}

save_nftables_rules() {
    if ! command -v nft >/dev/null 2>&1; then
        return 0
    fi

    if [ -f "/etc/nftables.conf" ]; then
        nft list ruleset > /etc/nftables.conf 2>/dev/null || true
    elif [ -f "/etc/sysconfig/nftables.conf" ]; then
        nft list ruleset > /etc/sysconfig/nftables.conf 2>/dev/null || true
    fi
}

close_nftables_port() {
    local port=$1
    if ! command -v nft >/dev/null 2>&1; then
        return 0
    fi

    nft -a list ruleset 2>/dev/null | awk -v port="$port" '
        $1 == "table" {
            family=$2; table=$3; gsub(/[{}]/, "", table)
        }
        $1 == "chain" {
            chain=$2; gsub(/[{}]/, "", chain)
        }
        ($0 ~ "tcp dport " port " .*accept" || $0 ~ "udp dport " port " .*accept") && /# handle/ {
            handle=$NF
            print family " " table " " chain " " handle
        }
    ' | while read -r family table chain handle; do
        [ -n "$handle" ] || continue
        nft delete rule "$family" "$table" "$chain" handle "$handle" 2>/dev/null || true
    done

    save_nftables_rules
}

close_port() {
    local port=$1
    [ -n "$port" ] || return 0

    if command -v ufw >/dev/null 2>&1; then
        ufw delete allow "$port"/tcp >/dev/null 2>&1 || true
        ufw delete allow "$port"/udp >/dev/null 2>&1 || true
    fi

    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
        iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
        if [ -d "/etc/iptables" ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
        fi
    fi

    close_nftables_port "$port"
}

# 卸载 Snell
uninstall_snell() {
    echo -e "${CYAN}正在卸载 Snell...${RESET}"

    # 停止并删除依赖 Snell 后端的 ShadowTLS 服务
    if [ -d "${SYSTEMD_DIR}" ]; then
        for service_file in "${SYSTEMD_DIR}"/shadowtls-snell-*.service; do
            [ -f "$service_file" ] || continue
            local service_name
            service_name=$(basename "$service_file" .service)
            local shadowtls_port
            shadowtls_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            echo -e "${YELLOW}正在停止 ShadowTLS 服务 (${service_name})${RESET}"
            service_stop "$service_name"
            rm -f "$service_file"
            if [ -n "$shadowtls_port" ]; then
                close_port "$shadowtls_port"
            fi
        done
    fi

    # 停止主服务
    service_stop snell
    service_stop snell.socket
    service_stop snell-netns

    # 停止并禁用所有多用户服务
    if [ -d "/etc/snell/users" ]; then
        for user_conf in /etc/snell/users/*; do
            [ -f "$user_conf" ] || continue
            local port
            port=$(grep -E '^listen' "$user_conf" 2>/dev/null | sed -n 's/.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p')
            if [ -n "$port" ]; then
                echo -e "${YELLOW}正在停止用户服务 (端口: $port)${RESET}"
                service_stop "snell-${port}"
                rm -f "${SYSTEMD_DIR}/snell-${port}.service" "/etc/init.d/snell-${port}"
                close_port "$port"
            fi
        done
    fi

    # 删除服务文件
    rm -f "/lib/systemd/system/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.service"
    rm -f "${SYSTEMD_DIR}/snell.socket"
    rm -f "${SYSTEMD_DIR}/snell-netns.service"
    rm -f "/etc/init.d/snell"
    rm -f "/usr/local/bin/snell-netns-setup.sh"

    # 删除可执行文件和配置目录
    rm -f /usr/local/bin/snell-server
    rm -rf /etc/snell
    rm -f /usr/local/bin/snell

    if ! ls "${SYSTEMD_DIR}"/shadowtls-*.service >/dev/null 2>&1 && ! ls /etc/init.d/shadowtls-* >/dev/null 2>&1; then
        rm -f /usr/local/bin/shadow-tls
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    echo -e "${GREEN}Snell 及其所有配置已成功卸载${RESET}"
}

# 卸载 SS-2022
uninstall_ss_rust() {
    echo -e "${CYAN}正在卸载 SS-2022...${RESET}"

    # 获取主服务端口，用于关闭防火墙
    local main_port=""
    if [ -f "/etc/ss-rust/config.json" ]; then
        main_port=$(grep -oE '"server_port"[[:space:]]*:[[:space:]]*[0-9]+' /etc/ss-rust/config.json 2>/dev/null | grep -oE '[0-9]+' | head -n 1)
    fi

    # 停止主服务
    service_stop ss-rust
    rm -f "${SYSTEMD_DIR}/ss-rust.service" "/etc/init.d/ss-rust"
    if [ -n "$main_port" ]; then
        close_port "$main_port"
    fi

    # 清理多端口节点服务
    if [ -d "${SYSTEMD_DIR}" ]; then
        for extra_service in "${SYSTEMD_DIR}"/ss-rust-*.service; do
            [ -f "$extra_service" ] || continue
            local svc_name
            svc_name=$(basename "$extra_service" .service)
            local extra_port="${svc_name#ss-rust-}"
            echo -e "${YELLOW}正在停止多端口服务 (端口: ${extra_port})${RESET}"
            service_stop "$svc_name"
            rm -f "$extra_service"
            case "$extra_port" in
                ''|*[!0-9]*) ;;
                *) close_port "$extra_port" ;;
            esac
        done
    fi

    # 删除二进制文件和配置目录
    rm -f "/usr/local/bin/ss-rust" "/usr/local/bin/ssrust"
    rm -rf "/etc/ss-rust"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    echo -e "${GREEN}SS-2022 卸载完成！${RESET}"
}

# 卸载 ShadowTLS
uninstall_shadowtls() {
    echo -e "${CYAN}正在卸载 ShadowTLS...${RESET}"

    if [ -d "${SYSTEMD_DIR}" ]; then
        for service_file in "${SYSTEMD_DIR}"/shadowtls-*.service; do
            [ -f "$service_file" ] || continue
            local service
            service=$(basename "$service_file" .service)
            local listen_port
            listen_port=$(sed -n 's/.*--listen .*:\([0-9][0-9]*\).*/\1/p' "$service_file" | head -n 1)
            echo -e "${YELLOW}正在移除 ${service}${RESET}"
            service_stop "$service"
            rm -f "$service_file"
            if [ -n "$listen_port" ]; then
                close_port "$listen_port"
            fi
        done
    fi

    # 删除二进制文件
    rm -f "/usr/local/bin/shadow-tls"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    echo -e "${GREEN}ShadowTLS 卸载完成！${RESET}"
}

# 主菜单
show_menu() {
    clear 2>/dev/null || true
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${CYAN}          统一管理脚本 v${current_version}${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}作者: jinqian${RESET}"
    echo -e "${GREEN}网站：https://jinqians.com${RESET}"
    echo -e "${CYAN}============================================${RESET}"

    # 显示服务状态
    check_and_show_status

    echo -e "${YELLOW}=== 安装管理 ===${RESET}"
    echo -e "${GREEN}1.${RESET} Snell 安装管理"
    echo -e "${GREEN}2.${RESET} SS-2022 安装管理"
    echo -e "${GREEN}3.${RESET} VLESS Reality 安装管理"
    echo -e "${GREEN}4.${RESET} ShadowTLS 安装管理"

    echo -e "\n${YELLOW}=== 卸载功能 ===${RESET}"
    echo -e "${GREEN}5.${RESET} 卸载 Snell"
    echo -e "${GREEN}6.${RESET} 卸载 SS-2022"
    echo -e "${GREEN}7.${RESET} 卸载 ShadowTLS"

    echo -e "\n${YELLOW}=== 系统功能 ===${RESET}"
    echo -e "${GREEN}8.${RESET} 更新脚本"
    echo -e "${GREEN}9.${RESET} 流量管理（推荐使用 PSM 管理）"
    echo -e "${GREEN}10.${RESET} 中国大陆屏蔽管理(ss-2022)"
    echo -e "${GREEN}0.${RESET} 退出"

    echo -e "${CYAN}============================================${RESET}"
    echo -e "${GREEN}退出脚本后，输入 menu 可重新进入脚本${RESET}"
    echo -e "${CYAN}============================================${RESET}"
    printf "%b" "请输入选项 [0-10]: "
    read -r num
}

# 初始检查
check_root
check_dependencies
install_global_command

# 主循环
while true; do
    show_menu
    case "$num" in
        1)
            manage_snell
            ;;
        2)
            manage_ss_rust
            ;;
        3)
            manage_vless
            ;;
        4)
            manage_shadowtls
            ;;
        5)
            uninstall_snell
            ;;
        6)
            uninstall_ss_rust
            ;;
        7)
            uninstall_shadowtls
            ;;
        8)
            update_script
            ;;
        9)
            echo -e "\n${YELLOW}=== 流量管理 ===${RESET}"
            echo -e "推荐使用 ${GREEN}PSM（Proxy Stack Manager）${RESET} 进行流量管理。"
            echo -e "\nPSM 支持 Snell / SS2022 / Xray 等协议的统一流量限额管理，功能包括："
            echo -e "  • 设置月度流量上限（GB）及自动重置日"
            echo -e "  • 超限自动暂停节点，恢复后自动解封"
            echo -e "  • iptables 精确计数，数据持久化保存"
            echo -e "\n安装 PSM："
            echo -e "  ${CYAN}curl -fsSL https://psm.jinqians.com | sh${RESET}"
            printf "%b" "按回车键继续..."
            read -r _dummy
            ;;
        10)
            if ! manage_mainland_block; then
                echo -e "${YELLOW}请检查仓库地址或网络连接后重试${RESET}"
                printf "%b" "按回车键继续..."
                read -r _dummy
            fi
            ;;
        0)
            echo -e "${GREEN}感谢使用，再见！${RESET}"
            exit 0
            ;;
        *)
            echo -e "${RED}请输入正确的选项 [0-10]${RESET}"
            ;;
    esac
    echo -e "\n${CYAN}按回车键返回主菜单...${RESET}"
    read -r _dummy
done
