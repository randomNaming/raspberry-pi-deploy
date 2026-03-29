# HCP Simulator Lite 部署指南

> 树莓派 4B 部署完整指南，包含 VPN 配置、Nacos 注册和 systemd 服务管理

## 目录

1. [概述](#1-概述)
2. [硬件要求](#2-硬件要求)
3. [系统准备](#3-系统准备)
4. [WireGuard VPN 配置](#4-wireguard-vpn-配置)
5. [部署方法](#5-部署方法)
6. [Systemd 服务配置](#6-systemd-服务配置)
7. [配置说明](#7-配置说明)
8. [使用说明](#8-使用说明)
9. [日志查看](#9-日志查看)
10. [验证步骤](#10-验证步骤)
11. [故障排查](#11-故障排查)
12. [常见问题 FAQ](#12-常见问题-faq)
13. [附录：快速参考](#13-附录快速参考)

---

## 1. 概述

本文档描述如何在树莓派 4B 上部署 HCP Simulator Lite 服务，实现与云快充平台的连接。部署需要通过 WireGuard VPN 实现内网通信，并通过 Nacos 进行服务注册。

### 前置条件

- ✅ 服务器端 WireGuard VPN 已配置完成
- ✅ 服务器端 Nacos 服务正常运行
- ✅ 服务器端网关和 operator 服务已配置为使用 VPN IP 注册
- ✅ 树莓派已安装 Raspberry Pi OS（64-bit）
- ✅ 树莓派已连接到互联网

### 部署流程概览

1. [配置 WireGuard VPN 客户端](#4-wireguard-vpn-配置)
2. [安装 Java 运行环境](#3-系统准备)
3. [部署应用文件](#5-部署方法)
4. [配置 systemd 服务](#6-systemd-服务配置)
5. [配置 Nacos 注册](#7-配置说明)
6. [启动和验证](#10-验证步骤)

---

## 2. 硬件要求

- **树莓派 4B**（推荐 4GB 或 8GB RAM 版本）
- **MicroSD 卡**（32GB+，Class 10 或更高）
- **网络连接**（有线以太网或 WiFi）
- **电源适配器**（5V/3A，官方推荐）
- **可选**：散热风扇（长时间运行建议）

---

## 3. 系统准备

### 3.1 安装 Raspberry Pi OS

1. 从 [Raspberry Pi 官网](https://www.raspberrypi.org/software/) 下载 **Raspberry Pi Imager**
2. 使用 Imager 将 **Raspberry Pi OS (64-bit)** 烧录到 MicroSD 卡
3. 首次启动前，在 SD 卡根目录创建以下文件以启用 SSH 和配置 WiFi（如需要）：
   - `ssh`（空文件，启用 SSH）
   - `wpa_supplicant.conf`（WiFi 配置，如使用有线网络可跳过）

### 3.2 初始配置

1. 将 SD 卡插入树莓派，连接电源和网络
2. 通过 SSH 连接到树莓派（默认用户名：`pi`，密码：`raspberry`）
   ```bash
   ssh pi@<树莓派IP地址>
   ```
3. 更新系统：
   ```bash
   sudo apt update
   sudo apt upgrade -y
   ```

### 3.3 安装 Java 17+

脚本会自动检测并安装 Java。如需手动安装：

```bash
sudo apt install openjdk-17-jdk -y
java -version
```

---

## 4. WireGuard VPN 配置

### 4.1 VPN IP 分配表

| 设备 | VPN IP | 实例 ID | 说明 |
|------|--------|---------|------|
| 服务器 | 10.0.0.1 | - | WireGuard VPN 服务器 |
| 树莓派 1 | 10.0.0.2 | pi-01 | 第一台树莓派 |
| 树莓派 2 | 10.0.0.3 | pi-02 | 第二台树莓派 |
| 树莓派 3 | 10.0.0.4 | pi-03 | 第三台树莓派 |
| 树莓派 4 | 10.0.0.5 | pi-04 | 第四台树莓派 |

> **重要**：每台树莓派的 VPN IP 必须唯一！

### 4.2 服务器端配置

在服务器上执行以下步骤，为新的树莓派生成配置：

```bash
cd /etc/wireguard

# 为树莓派生成密钥对
sudo wg genkey | sudo tee pi-02_private.key | sudo wg pubkey | sudo tee pi-02_public.key
sudo chmod 600 pi-02_private.key

# 查看公钥
sudo cat pi-02_public.key
```

编辑服务器 WireGuard 配置文件，添加 `[Peer]` 块：

```bash
sudo nano /etc/wireguard/wg0.conf
```

```ini
[Peer]
PublicKey = <树莓派公钥>
AllowedIPs = 10.0.0.3/32
```

重载配置：

```bash
sudo wg syncconf wg0 <(sudo wg-quick strip wg0)
```

### 4.3 树莓派端配置

部署脚本会自动完成 WireGuard 安装和配置。如需手动配置：

```bash
sudo apt install wireguard wireguard-tools -y

sudo mkdir -p /etc/wireguard
cd /etc/wireguard

# 生成密钥对
sudo wg genkey | sudo tee pi_private.key | sudo wg pubkey | sudo tee pi_public.key
sudo chmod 600 pi_private.key

# 查看公钥（发送给服务器管理员）
sudo cat pi_public.key
```

客户端配置文件：

```bash
sudo nano /etc/wireguard/wg0.conf
```

```ini
[Interface]
PrivateKey = <树莓派私钥>
Address = 10.0.0.3/24

[Peer]
PublicKey = <服务器公钥>
Endpoint = <服务器公网IP>:51820
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
```

启动并验证：

```bash
sudo systemctl enable wg-quick@wg0
sudo systemctl start wg-quick@wg0
sudo wg show
ping -c 3 10.0.0.1
```

---

## 5. 部署方法

### 方法一：一键自动部署（推荐）

#### 准备工作

1. **准备文件**：将 `hcp-simulator-lite.jar` 放在脚本同目录
2. **上传到树莓派**：
   ```bash
   scp -r raspberry-pi-deploy pi@<树莓派IP>:/home/pi/
   scp hcp-simulator-lite.jar pi@<树莓派IP>:/home/pi/raspberry-pi-deploy/
   ```
3. **SSH 连接到树莓派**：
   ```bash
   ssh pi@<树莓派IP>
   ```

#### 执行部署

```bash
cd ~/raspberry-pi-deploy
chmod +x deploy-interactive.sh install.sh
./deploy-interactive.sh
```

选择 **「一键自动部署」**，脚本会自动完成：

- ✅ 环境检测
- ✅ 备份快照
- ✅ WireGuard VPN 配置
- ✅ Java 安装
- ✅ 目录创建
- ✅ JAR 部署
- ✅ 配置文件生成
- ✅ systemd 服务安装与启动

### 方法二：手动分步部署

运行 `./deploy-interactive.sh`，选择 **「手动部署模式」**，按需执行各步骤。

---

## 6. Systemd 服务配置

### 6.1 服务文件内容

部署脚本会自动生成服务文件。服务文件位于：

```bash
/etc/systemd/system/hcp-simulator-lite.service
```

示例内容（**VPN IP 和实例 ID 需根据实际设备修改**）：

```ini
[Unit]
Description=HCP Simulator Lite - 云快充模拟桩服务
After=network.target wg-quick@wg0.service
Requires=wg-quick@wg0.service

[Service]
Type=simple
User=pi
Group=pi
WorkingDirectory=/home/pi/hcp-simulator-lite
Environment="NACOS_HOST=10.0.0.1"
Environment="NACOS_PORT=8848"
Environment="SPRING_CLOUD_NACOS_DISCOVERY_IP=10.0.0.3"
Environment="SPRING_CLOUD_NACOS_DISCOVERY_PORT=18080"
Environment="SIMULATOR_INSTANCE_ID=pi-02"
ExecStart=/usr/bin/java -Xms256m -Xmx1024m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Dfile.encoding=UTF-8 -Dspring.profiles.active=prod -jar /home/pi/hcp-simulator-lite/hcp-simulator-lite.jar
ExecStop=/bin/kill -15 $MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hcp-simulator-lite
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

> **重要**：`SPRING_CLOUD_NACOS_DISCOVERY_IP` 必须与 WireGuard VPN IP 一致，否则 Nacos 注册的实例 IP 会与实际 VPN IP 不匹配，导致网关无法调用服务。部署脚本会自动同步这两个值。

### 6.2 启用并启动服务

```bash
sudo systemctl daemon-reload
sudo systemctl enable hcp-simulator-lite
sudo systemctl start hcp-simulator-lite
sudo systemctl status hcp-simulator-lite
```

---

## 7. 配置说明

### 7.1 环境配置

应用支持多环境配置，通过 Spring Profile 区分：

- **开发环境** (`dev`)：使用 `application-dev.yml`
- **生产环境** (`prod`)：使用 `application-prod.yml`

### 7.2 关键配置项

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| `server.port` | REST API 端口 | 18080 |
| `NACOS_HOST` | Nacos 服务器地址 | 10.0.0.1 |
| `NACOS_PORT` | Nacos 端口 | 8848 |
| `SPRING_CLOUD_NACOS_DISCOVERY_IP` | 注册到 Nacos 的 IP | VPN 内网 IP |
| `SIMULATOR_INSTANCE_ID` | 实例标识 | pi-01 / pi-02 / ... |

### 7.3 桩配置格式

```yaml
ykc:
  piles:
    - pile-code: "320106XXXXXXXX"  # 桩编号（14位）
      guns: ["01", "02"]           # 枪号列表
```

### 7.4 临时快速测试配置

#### 临时充电快速测试（从 97% 开始充电）

```bash
java -Dsimulator.test.startSoc=97 -jar hcp-simulator-lite.jar --spring.profiles.active=dev
```

#### 临时快速充电倍速测试

```bash
# 开启 5 倍速度
java -Dsimulator.test.fastCharge=true -jar hcp-simulator-lite.jar --spring.profiles.active=dev

# 自定义倍速（1~20）
java -Dsimulator.test.fastCharge=10 -jar hcp-simulator-lite.jar --spring.profiles.active=dev
```

---

## 8. 使用说明

### 8.1 启动桩

程序启动后，桩不会自动连接。需要通过 REST API 手动启动：

```bash
# 启动桩
curl -X GET "http://<树莓派IP>:18080/evcs/sim/v1/start?pileId=320106XXXXXXXX"

# 停止桩
curl -X GET "http://<树莓派IP>:18080/evcs/sim/v1/stop?pileId=320106XXXXXXXX"
```

### 8.2 查询桩状态

```bash
# 查询单个桩
curl -X GET "http://<树莓派IP>:18080/evcs/sim/v1/status?pileId=320106XXXXXXXX"

# 查询所有桩
curl -X GET "http://<树莓派IP>:18080/sim/piles"
```

### 8.3 插枪/拔枪

```bash
# 插枪
curl -X GET "http://<树莓派IP>:18080/evcs/sim/v1/link?pileId=320106XXXXXXXX&deviceId=01"

# 拔枪
curl -X GET "http://<树莓派IP>:18080/evcs/sim/v1/unlink?pileId=320106XXXXXXXX&deviceId=01"
```

### 8.4 完整充电流程

1. **启动桩**：`GET /evcs/sim/v1/start?pileId=xxx`
2. **等待桩上线**：桩会自动登录并完成计费模型验证
3. **插枪**：`GET /evcs/sim/v1/link?pileId=xxx&deviceId=01`
4. **小程序扫码启充**：平台下发远程启机指令，程序自动处理
5. **充电中**：程序自动上送实时数据，SOC 自动增长
6. **停止充电**：小程序停充或 SOC 达到 100% 自动停止
7. **交易记录**：程序自动上送交易记录
8. **拔枪**：`GET /evcs/sim/v1/unlink?pileId=xxx&deviceId=01`

---

## 9. 日志查看

### 9.1 实时日志

```bash
# 查看服务日志
sudo journalctl -u hcp-simulator-lite -f

# 查看最近 100 行
sudo journalctl -u hcp-simulator-lite -n 100
```

### 9.2 日志文件位置

- 应用日志：`~/hcp-simulator-lite/logs/`
- 部署日志：`~/.hcp-deploy.log`
- SQLite 数据库：`~/hcp-simulator-lite/data/simulator.db`

---

## 10. 验证步骤

### 10.1 VPN 连接验证

```bash
# 检查 WireGuard 状态
sudo wg show

# 测试 VPN 连通性
ping -c 3 10.0.0.1

# 测试 Nacos 连接
curl http://10.0.0.1:8848/nacos/v1/console/health
```

### 10.2 Nacos 注册验证

1. 访问 Nacos 控制台：`http://<服务器公网IP>:8848/nacos`
2. 进入 `服务管理` → `服务列表` → `hcp-simulator-lite`
3. 检查实例 IP 是否为 VPN IP（如 `10.0.0.3`）
4. 检查健康状态是否为 `true`

### 10.3 服务调用验证

```bash
# 从服务器测试
curl http://10.0.0.3:18080/actuator/health

# 查看应用日志
sudo journalctl -u hcp-simulator-lite -n 50 | grep -i "注册\|nacos\|error"
```

---

## 11. 故障排查

### 11.1 VPN 无法连接

```bash
# 检查服务状态
sudo systemctl status wg-quick@wg0

# 检查配置语法
sudo wg-quick strip wg0

# 查看已连接的客户端
sudo wg show
```

### 11.2 Nacos 注册 IP 错误

```bash
# 检查环境变量
sudo systemctl show hcp-simulator-lite | grep SPRING_CLOUD_NACOS_DISCOVERY_IP

# 编辑服务文件修改 IP
sudo nano /etc/systemd/system/hcp-simulator-lite.service

# 重启服务
sudo systemctl daemon-reload
sudo systemctl restart hcp-simulator-lite
```

### 11.3 网关无法访问服务

```bash
# 从服务器测试连接
curl http://<树莓派VPN_IP>:18080/actuator/health

# 确认注册 IP 是 VPN IP，不是本地网络 IP
```

### 11.4 程序无法启动

```bash
# 检查 Java
java -version

# 检查端口占用
sudo ss -tlnp | grep 18080

# 查看详细日志
sudo journalctl -u hcp-simulator-lite -n 50 --no-pager
```

### 11.5 桩无法连接平台

1. 检查网络连接：
   ```bash
   ping <平台服务器IP>
   ```
2. 检查防火墙：
   ```bash
   sudo ufw status
   ```
3. 检查平台地址和端口配置是否正确

---

## 12. 常见问题 FAQ

**Q: 支持多少个桩？**

A: 理论上支持无限个，但建议不超过 12 个桩（每桩 2 枪），以确保在树莓派 4B 上稳定运行。

**Q: 如何批量启动所有桩？**

A: 编写脚本批量调用：

```bash
#!/bin/bash
for pile in 320106XXXXXXXX 320106XXXXXXXY 320106XXXXXXXZ; do
  curl -X GET "http://localhost:18080/evcs/sim/v1/start?pileId=$pile"
  sleep 2
done
```

**Q: 程序崩溃后如何恢复？**

A: systemd 服务配置了自动重启（`Restart=always`），崩溃后 10 秒自动恢复。

**Q: 如何备份数据？**

A: 备份 SQLite 数据库文件：

```bash
cp ~/hcp-simulator-lite/data/simulator.db ~/backup/simulator_$(date +%Y%m%d).db
```

**Q: 内存不足怎么办？**

A: 在 systemd 服务文件中限制 JVM 堆内存（`-Xmx512m`）。树莓派 4B 4GB 版本建议 512MB~1GB。

**Q: 部署中断了怎么办？**

A: 运行 `./deploy-interactive.sh`，选择「恢复中断的部署」，脚本会从断点继续。

**Q: 如何回滚到部署前的状态？**

A: 一键部署前会自动创建快照。运行 `./deploy-interactive.sh`，选择「快照与回滚」进行恢复。

---

## 13. 附录：快速参考

### 常用命令

```bash
# 服务管理
sudo systemctl start hcp-simulator-lite
sudo systemctl stop hcp-simulator-lite
sudo systemctl restart hcp-simulator-lite
sudo systemctl status hcp-simulator-lite
sudo journalctl -u hcp-simulator-lite -f

# VPN 管理
sudo systemctl start wg-quick@wg0
sudo systemctl stop wg-quick@wg0
sudo wg show

# 配置检查
sudo systemctl show hcp-simulator-lite | grep Environment
sudo cat /etc/systemd/system/hcp-simulator-lite.service
sudo cat /etc/wireguard/wg0.conf
```

### 部署检查清单

#### 服务器端

- [ ] WireGuard VPN 服务器已配置并运行
- [ ] Nacos 服务正常运行
- [ ] 网关和 operator 服务已配置为使用 VPN IP 注册
- [ ] 云服务器安全组已开放 UDP 51820 端口（WireGuard）

#### 树莓派端

- [ ] Raspberry Pi OS（64-bit）已安装
- [ ] WireGuard VPN 已安装并启动
- [ ] VPN IP 配置正确且唯一
- [ ] 可以 ping 通服务器 VPN IP（10.0.0.1）
- [ ] Java 17 已安装
- [ ] JAR 文件已上传
- [ ] systemd 服务文件已配置
- [ ] `SPRING_CLOUD_NACOS_DISCOVERY_IP` 与 VPN IP 一致
- [ ] `SIMULATOR_INSTANCE_ID` 设置为唯一值
- [ ] 服务已启动并运行正常

### 服务器信息（请填写实际值）

| 项目 | 值 |
|------|----|
| 服务器公网 IP | `<YOUR_SERVER_PUBLIC_IP>` |
| VPN 内网 IP | `10.0.0.1` |
| Nacos 端口 | `8848` |
| WireGuard 端口 | `51820` |
| 网关端口 | `38080` |

---

**最后更新**：2026-03-29
