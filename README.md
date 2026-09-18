# Shadowsocks Rust + ShadowTLS 安装与综合管理脚本套件

这是一个用于在各类 Linux 服务器（Debian / Ubuntu / CentOS / RHEL / Rocky / **Alpine Linux (musl)** / **BusyBox (`ash`)** / Arch / OpenWrt / Void 等）上快速安装、配置和管理 **Shadowsocks Rust (SS-2022)**、**ShadowTLS V3** 及 **中国大陆 IP 防火墙屏蔽** 的一站式工具集合。全套脚本采用纯 POSIX `/bin/sh` 标准重构，零 bash 语法强依赖，全面支持 systemd、OpenRC 及 SysVinit 服务管理。

---

## 脚本清单与架构

本项目包含 5 个核心脚本，分工明确、协同工作：

| 脚本文件 | 类型 | 说明与主要职责 |
| :--- | :--- | :--- |
| **`menu.sh`** | POSIX Shell | **全局统一控制台（推荐入口）**。整合所有脚本的交互式 TUI，支持跨 init 系统查看各服务资源占用（CPU/内存）、统一安装/卸载清理、配置全局 `menu` 快捷指令 |
| **`ss-2022.sh`** | POSIX Shell | **Shadowsocks Rust 核心管理**。自动适配 musl/glibc，支持安装、更新、卸载、多端口管理、客户端配置导出（Surge/Clash/Shadowrocket）及终端二维码 |
| **`shadowtls.sh`** | POSIX Shell | **ShadowTLS V3 伪装增强**。为 SS-Rust 或 Snell 后端套上真实 TLS 握手特征，防止主动探测，自动生成复合配置与防火墙放行规则 |
| **`block-mainland.sh`** | POSIX Shell | **中国大陆 IP 来源屏蔽**。基于 `ipset` + `iptables` 阻断来自中国大陆 IP 段对各节点端口的访问，支持开机自动恢复与定时更新 |
| **`extract-cn-ip-from-mmdb.py`** | Python | **GeoIP2 数据解析工具**。利用 `maxminddb` 库从 MaxMind 数据库中提取、去重并排序全部中国 IPv4 CIDR 段，供屏蔽脚本使用 |

```
                ┌────────────────────────────────────────────────────────┐
                │                       menu.sh                          │
                │        (全局统一主控 / 状态监控 / 快捷命令 menu)         │
                └──────┬──────────────────┬───────────────────┬──────────┘
                       │                  │                   │
                       ▼                  ▼                   ▼
                ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐
                │  ss-2022.sh  │   │ shadowtls.sh │   │ block-mainland.sh│
                │ (SS-Rust后端)│◄──┤ (TLS流量伪装)│   │  (ipset+iptables)│
                └──────────────┘   └──────────────┘   └────────┬─────────┘
                                                               │
                                                               ▼
                                                  ┌────────────────────────┐
                                                  │extract-cn-ip-from-mmdb │
                                                  │ (解析 mmdb 提取 CN IP) │
                                                  └────────────────────────┘
```

---

## 快速使用

> [!NOTE]
> 请确保系统已安装基础工具（如 `curl` 或 `wget`），且以 **root** 权限运行。脚本已原生支持 BusyBox `ash`、Alpine `apk`、Debian `apt`、RHEL `dnf`/`yum`、Arch `pacman`、OpenWrt `opkg` 等主流环境。

### 方式一：推荐运行统一管理菜单（一站式管理）

首次运行会自动将快捷命令注册到 `/usr/local/bin/menu`，后续只需在终端输入 `menu` 即可随时唤起：

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/menu.sh)"
```
*或者先下载再执行：*
```sh
wget -O menu.sh https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/menu.sh && chmod +x menu.sh && ./menu.sh
```

---

### 方式二：独立执行各脚本（按需使用）

如果你只需要使用特定的功能模块，可以直接下载运行对应脚本：

#### 1. Shadowsocks Rust (SS-2022) 核心管理
```bash
wget -O ss-2022.sh https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/ss-2022.sh && chmod +x ss-2022.sh && ./ss-2022.sh
```

#### 2. ShadowTLS V3 伪装管理
```bash
wget -O shadowtls.sh https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/shadowtls.sh && chmod +x shadowtls.sh && ./shadowtls.sh
```

#### 3. 中国大陆 IP 屏蔽管理
```bash
wget -O block-mainland.sh https://raw.githubusercontent.com/Rain-kl/ss-2022.sh/main/block-mainland.sh && chmod +x block-mainland.sh && ./block-mainland.sh
```
*`block-mainland.sh` 也支持直接传入命令行参数：*
```bash
./block-mainland.sh enable              # 开启屏蔽并下发规则
./block-mainland.sh disable             # 禁用屏蔽并清空规则
./block-mainland.sh status              # 查看当前屏蔽与端口状态
./block-mainland.sh auto-update-enable  # 开启每日定时更新 IP 库
```

#### 4. MaxMind GeoIP2 提取工具 (Python)
若需要手动从自定义的 MaxMind 数据库中提取中国大陆 IP 段：
```bash
pip install maxminddb
python3 extract-cn-ip-from-mmdb.py Country.mmdb mainland_cn.txt
```

---

### 方式三：克隆仓库到本地使用

```bash
git clone https://github.com/Rain-kl/ss-2022.sh.git
cd ss-2022.sh
chmod +x *.sh
./menu.sh
```

---

## 详细功能特点

### 1. 统一管理菜单 (`menu.sh`)
- **系统与服务监控**：实时查看 Snell、SS-Rust、ShadowTLS 各服务的运行状态、实例数、单核 CPU 占用及物理内存。
- **协议集中调度**：统一管理 Snell、SS-2022、VLESS Reality（PSM 协同）以及 ShadowTLS。
- **彻底清理卸载**：提供对应组件的一键彻底卸载，自动关闭并清理 ufw、iptables、nftables 防火墙端口规则与残留服务。
- **全局快捷指令**：自动生成 `/usr/local/bin/menu` 软链接。

### 2. Shadowsocks Rust (`ss-2022.sh`)
- **完整生命周期**：安装、更新、卸载、启动、停止、重启与状态查询。
- **SS-2022 规范**：默认推荐 `2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`，修改加密方式时自动校验并匹配密钥长度。
- **多端口节点**：支持在单机上扩展部署多个独立端口的 SS 节点。
- **混淆与优化**：支持 simple-obfs 混淆插件，内置 TCP Fast Open (TFO) 优化。
- **多客户端格式生成**：自动生成 Surge、Clash Meta、Shadowrocket 节点配置及终端二维码。

### 3. ShadowTLS V3 (`shadowtls.sh`)
- **抗封锁伪装**：将 SS-Rust 或 Snell 后端包装在正常大站的 TLS 握手特征中，抵御主动探测。
- **多后端共存**：可分别为 SS-Rust 或多端口 Snell 创建独立的 systemd 守护进程。
- **网络与防火墙**：智能识别 IPv4/IPv6 双栈监听，自动放行入站端口，并在卸载时回收规则。
- **复合配置导出**：自动生成包含 TLS SNI 和 Password 的复合客户端节点。

### 4. 大陆 IP 屏蔽 (`block-mainland.sh` + `extract-cn-ip-from-mmdb.py`)
- **全端口动态防护**：自动扫描 SS 主端口、多端口节点及 ShadowTLS 端口，统一下发丢弃规则。
- **高性能 ipset**：内核态高效匹配数千条 CIDR，对网络吞吐几乎零损耗。
- **持久化防失效**：内置 `block-mainland.service` 开机服务，解决系统重启内核 ipset 丢失问题。
- **自动化运维**：支持配置系统 crontab，定时无感热更新中国 IP 列表。

---

## 支持的加密方式

### 推荐 Shadowsocks 2022 协议
- `2022-blake3-aes-128-gcm` (推荐)
- `2022-blake3-aes-256-gcm` (推荐)
- `2022-blake3-chacha20-poly1305`
- `2022-blake3-chacha8-poly1305`

### 传统 AEAD 协议
- `aes-128-gcm`
- `aes-256-gcm`
- `chacha20-ietf-poly1305`

---

## 客户端配置支持

脚本支持生成多种主流客户端配置格式与直连/合并链接：

- **Surge**：自动生成标准配置字段，支持包含 ShadowTLS 插件参数（`shadow-tls-password`、`shadow-tls-sni` 等）。
- **Clash Meta (Mihomo)**：自动生成完整的 YAML 代理节点配置与 ShadowTLS 插件块。
- **Shadowrocket**：提供 SS 节点及 ShadowTLS 节点配置说明与扫码支持。

---

## 流量管理说明

<details>
   <summary>展开查看流量限额管理详情</summary>

### 功能说明
通过 iptables 对 SS2022 / Snell 节点进行流量计数，支持设置月度流量上限，超限后自动暂停节点，每月指定日期自动重置。

### 计量原理
SS2022 监听在指定端口（TCP + UDP），流量管理通过在 iptables 中添加专用计数规则（`PSM_TRF` 链）统计该端口的进出字节数。超限时向 `INPUT` 链插入 DROP 规则，阻断新连接。

```
客户端 ──TCP/UDP──▶ iptables 计数 ──▶ ss-rust
                         │
                       超限时 DROP
```

### 使用方式
推荐使用配套的 **PSM（Proxy Stack Manager）** 进行统一流量限额管理：
```bash
bash <(curl -fsSL https://psm.jinqians.com)
```
进入 PSM 后选择 **15. 流量管理** → **添加节点** → 选择 SS2022，设置月度上限（GB）及重置日期。

### 自动检查定时器
配置后会安装 systemd 定时器（`psm-traffic.timer`），每分钟轮询检查一次：
- 累计流量 ≥ 限额 → 自动暂停节点（TCP + UDP 同时阻断）
- 到达重置日 → 计数归零并自动恢复节点

</details>

---

## 常见问题与状态排查

- **查看 SS-Rust 服务状态**：
  ```bash
  # systemd (Debian / Ubuntu / CentOS / Arch 等)
  systemctl status ss-rust

  # OpenRC (Alpine Linux)
  rc-service ss-rust status
  ```
- **查看 SS-Rust 日志**：
  ```bash
  # systemd
  journalctl -u ss-rust -e --no-pager -n 50

  # OpenRC / 独立日志文件
  tail -n 50 /var/log/ss-rust.log
  ```
- **查看 ShadowTLS 服务状态**：
  ```bash
  # systemd
  systemctl status shadowtls-ss

  # OpenRC (Alpine Linux)
  rc-service shadowtls-ss status
  ```
- **查看大陆屏蔽规则状态**：
  ```bash
  /usr/local/bin/block-mainland.sh status
  # 或查看 ipset 规则列表
  ipset list mainland_cn_src | head -n 10
  ```

---

## 作者与致谢

- 作者：jinqians
- 网站：[https://jinqians.com](https://jinqians.com)
