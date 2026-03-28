# HCP Simulator Lite - 交互式部署管理器

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Raspberry%20Pi%204B-green.svg)](https://www.raspberrypi.com/)
[![Shell](https://img.shields.io/badge/shell-bash%204.0+-yellow.svg)](https://www.gnu.org/software/bash/)

用于在树莓派 4B 上自动化部署和管理 **HCP Simulator Lite**（云快充模拟桩）的交互式部署工具。

## 功能特性

- **环境检测** - 自动检查操作系统、架构、Java、网络、磁盘等环境条件
- **一键部署** - 全自动完成从环境准备到服务启动的完整部署流程
- **手动部署** - 逐步部署，完全控制每个步骤
- **配置向导** - 引导式配置服务器、桩、VPN 参数
- **服务管理** - 启动、停止、重启、查看日志等 systemd 服务操作
- **快照回滚** - 部署前自动创建快照，支持快速回滚
- **镜像接管** - 重新部署现有环境，支持备份、更新、重装
- **断点续传** - 记录部署状态，中断后可继续部署

## 系统要求

| 项目 | 要求 |
|------|------|
| 硬件 | Raspberry Pi 4B (推荐 4GB+ 内存) |
| 系统 | Raspberry Pi OS 64-bit / Ubuntu 22.04+ |
| Java | OpenJDK 17+ |
| 磁盘 | 至少 5GB 可用空间 |
| 网络 | 需要访问外网（下载依赖） |

## 快速开始

### 一行命令安装（推荐）

**国内用户（Gitee，更快更稳定）：**

```bash
bash <(curl -sL https://gitee.com/garrettxia/raspberry-pi-deploy/raw/main/install.sh)
```

**海外用户（GitHub）：**

```bash
bash <(curl -sL https://raw.githubusercontent.com/randomNaming/raspberry-pi-deploy/main/install.sh)
```

安装完成后，可使用快捷命令运行：

```bash
hcp-deploy
```

**一键更新：**

```bash
hcp-update
```

### 手动安装

```bash
# 1. 克隆仓库
git clone https://github.com/randomNaming/raspberry-pi-deploy.git
cd raspberry-pi-deploy

# 2. 添加执行权限
chmod +x deploy-interactive.sh

# 3. 运行部署脚本
./deploy-interactive.sh
```

### 4. 选择部署模式

```
========================================
  HCP Simulator Lite
  交互式部署管理器
  树莓派4B版
========================================

  服务状态: 已停止
  应用目录: /home/pi/hcp-simulator-lite

  [1] 一键自动部署
  [2] 环境检测
  [3] 手动部署
  [4] 镜像接管
  [5] 继续部署
  [6] 服务管理
  [7] 配置管理
  [8] 回滚
  [9] 查看日志
  [0] 退出

  选择 [0-9]:
```

## 项目结构

```
raspberry-pi-deploy/
├── install.sh               # 一键安装引导脚本
├── deploy-interactive.sh    # 主入口脚本
└── lib/
    ├── common.sh            # 通用工具函数（日志、颜色、用户交互）
    ├── state.sh             # 状态管理（部署进度记录）
    ├── env-check.sh         # 环境检测（系统、Java、网络、磁盘）
    ├── install.sh           # 安装部署（Java、目录、JAR、配置、服务）
    ├── config.sh            # 配置管理（服务器、桩、VPN 配置）
    ├── service.sh           # 服务管理（systemd 服务操作）
    ├── snapshot.sh          # 快照与回滚（备份、恢复、接管）
    └── resume.sh            # 继续部署（断点续传）
```

## 功能说明

### 一键自动部署

自动完成以下步骤：
1. 环境检测
2. 创建备份快照
3. 安装 Java 17
4. 创建目录结构
5. 部署 JAR 文件
6. 部署配置文件
7. 部署系统服务
8. 配置并启动服务

### 配置向导

部署过程中会引导配置以下参数：

| 配置项 | 说明 | 默认值 |
|--------|------|--------|
| 服务器地址 | 云快充平台地址 | 121.43.69.62 |
| 服务器端口 | 平台通信端口 | 8767 |
| 协议版本 | 通信协议版本 | V160 |
| 软件版本 | 客户端版本号 | V1.6.0 |
| 桩编号 | 14 位数字桩编号 | - |
| 枪号 | 每桩的枪号列表 | 01 02 |
| VPN IP | WireGuard VPN 地址 | 10.0.0.2 |
| 实例 ID | 模拟器实例标识 | pi-01 |

### 服务管理

支持以下操作：
- 查看状态
- 启动/停止/重启服务
- 查看实时日志/最近日志
- 启用/禁用开机自启

### 快照回滚

每次部署前自动创建快照，支持：
- 扫描当前安装状态
- 备份当前状态
- 回滚到指定快照
- 从备份恢复

## 常用命令

```bash
# 查看服务状态
sudo systemctl status hcp-simulator-lite

# 查看实时日志
sudo journalctl -u hcp-simulator-lite -f

# 停止服务
sudo systemctl stop hcp-simulator-lite

# 重启服务
sudo systemctl restart hcp-simulator-lite

# 查看部署日志
cat ~/.hcp-deploy.log | tail -50
```

## 目录说明

| 目录 | 说明 |
|------|------|
| `~/hcp-simulator-lite/` | 应用主目录 |
| `~/hcp-simulator-lite/data/` | 数据存储目录 |
| `~/hcp-simulator-lite/logs/` | 应用日志目录 |
| `~/hcp-simulator-lite/config/` | 配置文件目录 |
| `~/.hcp-deploy-backup/` | 快照备份目录 |
| `~/.hcp-deploy.log` | 部署日志文件 |
| `~/.hcp-deploy-state` | 部署状态文件 |

## 注意事项

1. **不要使用 root 用户运行** - 脚本会自动检测并警告
2. **JAR 文件准备** - 部署前需将 `hcp-simulator-lite.jar` 放置到脚本目录或 home 目录
3. **网络要求** - 需要访问外网下载 Java 依赖
4. **VPN 可选** - WireGuard VPN 为可选配置，不影响基本功能
5. **备份重要** - 镜像接管和重装前会自动备份，建议手动备份重要数据

## 故障排除

### 部署中断后继续

```bash
./deploy-interactive.sh
# 选择 [5] 继续部署
```

### 服务启动失败

```bash
# 查看服务日志
sudo journalctl -u hcp-simulator-lite -n 50

# 查看部署日志
tail -50 ~/.hcp-deploy.log
```

### 回滚到之前状态

```bash
./deploy-interactive.sh
# 选择 [8] 回滚
# 选择要回滚的快照 ID
```

## 更新日志

### v2.0.0 (2026-03-27)
- 重构为模块化架构
- 修复非交互环境下的循环问题
- 修复快照创建的 date 命令 bug
- 修复配置保存的作用域问题
- 添加中文注释

## 许可证

MIT License
