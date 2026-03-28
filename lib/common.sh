#!/bin/bash
# =============================================================================
# 通用工具函数库
# 提供日志、颜色输出、用户交互等基础功能
# =============================================================================

# -----------------------------------------------
# 全局常量
# -----------------------------------------------
readonly SCRIPT_VERSION="2.3.1"
readonly APP_NAME="hcp-simulator-lite"
readonly APP_DIR="${HOME}/${APP_NAME}"
readonly STATE_FILE="${HOME}/.hcp-deploy-state"
readonly LOG_FILE="${HOME}/.hcp-deploy.log"
readonly BACKUP_DIR="${HOME}/.hcp-deploy-backup"
readonly JAVA_MIN_VERSION=8
readonly JAR_FILE="${APP_NAME}.jar"
readonly SERVICE_NAME="${APP_NAME}.service"
readonly VPN_SERVICE="wg-quick@wg0.service"
readonly TEMP_DIR="/tmp/hcp-deploy-$$"

# 脚本所在目录（兼容管道执行方式）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# -----------------------------------------------
# 颜色定义
# -----------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# -----------------------------------------------
# 日志函数
# -----------------------------------------------

# 写入日志文件
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

# -----------------------------------------------
# 彩色输出函数
# -----------------------------------------------

# 信息输出（绿色）
print_info() {
    echo -e "${GREEN}[信息]${NC} $*"
    log "INFO" "$*"
}

# 警告输出（黄色）
print_warn() {
    echo -e "${YELLOW}[警告]${NC} $*"
    log "WARN" "$*"
}

# 错误输出（红色）
print_error() {
    echo -e "${RED}[错误]${NC} $*"
    log "ERROR" "$*"
}

# 成功输出（绿色加粗）
print_success() {
    echo -e "${GREEN}[完成]${NC} $*"
    log "OK" "$*"
}

# 步骤标题（青色）
print_step() {
    echo
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  步骤: $*${NC}"
    echo -e "${CYAN}========================================${NC}"
    log "STEP" "$*"
}

# 主标题（蓝色）
print_header() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# 子标题（紫色）
print_subheader() {
    echo
    echo -e "${MAGENTA}--- $* ---${NC}"
}

# -----------------------------------------------
# 用户交互函数
# -----------------------------------------------

# 确认操作（修复非交互环境问题）
confirm() {
    local prompt="${1:-继续?}"
    local default="${2:-y}"

    # 检查是否为交互式终端
    if [[ ! -t 0 ]]; then
        if [ "$default" = "y" ]; then
            print_warn "非交互环境，自动选择: 是"
            return 0
        else
            print_warn "非交互环境，自动选择: 否"
            return 1
        fi
    fi

    if [ "$default" = "y" ]; then
        read -p "$prompt [Y/n]: " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        read -p "$prompt [y/N]: " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# 安全读取输入（修复循环问题）
safe_read() {
    local prompt="$1"
    local default="${2:-}"
    local result

    # 检查是否为交互式终端
    if [[ ! -t 0 ]]; then
        echo "$default"
        return 0
    fi

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " result
        result="${result:-$default}"
    else
        read -p "$prompt: " result
    fi

    echo "$result"
}

# 安全读取单字符（修复循环问题）
# 用法: safe_read_char "提示" "返回变量名" ["默认值"]
safe_read_char() {
    local prompt="$1"
    local var_name="$2"
    local default="${3:-}"

    # 检查是否为交互式终端
    if [[ ! -t 0 ]]; then
        eval "$var_name='$default'"
        return 0
    fi

    local result=""
    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " -n 1 -r result || result=""
        echo
        result="${result:-$default}"
    else
        read -p "$prompt: " -n 1 -r result || result=""
        echo
    fi

    eval "$var_name='$result'"
}

# 暂停等待
pause() {
    if [[ -t 0 ]]; then
        print_info "按回车键继续..."
        read -r
    fi
}

# -----------------------------------------------
# 工具函数
# -----------------------------------------------

# 检查命令是否存在
command_exists() {
    command -v "$1" &>/dev/null
}

# 创建临时目录
create_temp_dir() {
    mkdir -p "$TEMP_DIR"
    echo "$TEMP_DIR"
}

# 清理临时文件
cleanup_temp() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}

# 获取当前时间戳
get_timestamp() {
    date '+%Y%m%d-%H%M%S'
}

# 获取当前日期时间
get_datetime() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 检查是否为root用户
is_root() {
    [ "$EUID" -eq 0 ]
}

# 执行命令（root用户不加sudo，普通用户加sudo）
run_as_root() {
    if is_root; then
        "$@"
    else
        sudo "$@"
    fi
}

# 确保目录存在
ensure_dir() {
    mkdir -p "$1"
}

# 检查文件是否存在且可读
file_readable() {
    [ -f "$1" ] && [ -r "$1" ]
}

# 安全执行命令（带错误处理）
safe_exec() {
    local cmd="$1"
    local error_msg="${2:-命令执行失败}"

    if ! eval "$cmd"; then
        print_error "$error_msg"
        return 1
    fi
    return 0
}

# 初始化环境
init_common() {
    ensure_dir "$(dirname "$LOG_FILE")"
    ensure_dir "$BACKUP_DIR"
    ensure_dir "$(dirname "$STATE_FILE")"
}
