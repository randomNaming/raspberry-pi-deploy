#!/bin/bash
# =============================================================================
# HCP Simulator Lite - 一键安装引导脚本
# 
# 使用方式：
#   bash <(curl -sL https://raw.githubusercontent.com/randomNaming/raspberry-pi-deploy/main/install.sh)
#
# 功能：从GitHub下载完整项目并启动部署管理器
# =============================================================================

set -euo pipefail

# -----------------------------------------------
# 颜色定义
# -----------------------------------------------
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# -----------------------------------------------
# 配置
# -----------------------------------------------
readonly GITHUB_REPO="randomNaming/raspberry-pi-deploy"
readonly GITHUB_BRANCH="main"
readonly INSTALL_DIR="${HOME}/.hcp-deploy"
readonly TEMP_DIR="/tmp/hcp-deploy-setup-$$"

# -----------------------------------------------
# 输出函数
# -----------------------------------------------
print_info() { echo -e "${GREEN}[信息]${NC} $*"; }
print_warn() { echo -e "${YELLOW}[警告]${NC} $*"; }
print_error() { echo -e "${RED}[错误]${NC} $*"; }
print_step() { echo -e "${CYAN}[步骤]${NC} $*"; }
print_success() { echo -e "${GREEN}[完成]${NC} $*"; }

# -----------------------------------------------
# 清理函数
# -----------------------------------------------
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# -----------------------------------------------
# 检查依赖
# -----------------------------------------------
check_deps() {
    local missing=()

    for cmd in curl tar bash; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "缺少必要依赖: ${missing[*]}"
        print_info "请先安装: sudo apt install -y ${missing[*]}"
        exit 1
    fi
}

# -----------------------------------------------
# 下载项目
# -----------------------------------------------
download_project() {
    print_step "下载项目文件..."

    mkdir -p "$TEMP_DIR"

    # 从GitHub下载仓库压缩包
    local archive_url="https://github.com/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

    if ! curl -sL "$archive_url" | tar xz -C "$TEMP_DIR" --strip-components=1; then
        print_error "下载失败，请检查网络连接"
        exit 1
    fi

    # 验证关键文件存在
    if [ ! -f "$TEMP_DIR/deploy-interactive.sh" ]; then
        print_error "下载不完整，未找到主脚本"
        exit 1
    fi

    if [ ! -d "$TEMP_DIR/lib" ]; then
        print_error "下载不完整，未找到lib目录"
        exit 1
    fi

    print_success "项目下载完成"
}

# -----------------------------------------------
# 安装到本地
# -----------------------------------------------
install_local() {
    print_step "安装部署工具..."

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 复制文件
    cp -r "$TEMP_DIR"/* "$INSTALL_DIR/"

    # 设置执行权限
    chmod +x "$INSTALL_DIR/deploy-interactive.sh"
    chmod +x "$INSTALL_DIR"/lib/*.sh

    print_success "安装完成: $INSTALL_DIR"
}

# -----------------------------------------------
# 运行部署管理器
# -----------------------------------------------
run_deployer() {
    echo
    print_step "启动部署管理器..."
    echo

    cd "$INSTALL_DIR"
    exec bash "$INSTALL_DIR/deploy-interactive.sh"
}

# -----------------------------------------------
# 显示使用说明
# -----------------------------------------------
show_usage() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  HCP Simulator Lite 一键安装${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    echo "安装完成后可使用以下命令运行："
    echo
    echo "  hcp-deploy"
    echo
    echo "或直接运行："
    echo
    echo "  bash ~/.hcp-deploy/deploy-interactive.sh"
    echo
}

# -----------------------------------------------
# 创建快捷命令
# -----------------------------------------------
create_alias() {
    local alias_file="${HOME}/.bashrc"

    # 检查是否已存在别名
    if grep -q "hcp-deploy" "$alias_file" 2>/dev/null; then
        return 0
    fi

    # 添加别名
    cat >> "$alias_file" << EOF

# HCP Simulator Lite 部署工具快捷命令
alias hcp-deploy='bash ~/.hcp-deploy/deploy-interactive.sh'
EOF

    print_info "已添加快捷命令: hcp-deploy"
    print_info "请执行: source ~/.bashrc 或重新登录以生效"
}

# -----------------------------------------------
# 主程序
# -----------------------------------------------
main() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  HCP Simulator Lite${NC}"
    echo -e "${BLUE}  一键安装引导程序${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo

    # 检查依赖
    check_deps

    # 下载项目
    download_project

    # 安装到本地
    install_local

    # 创建快捷命令
    create_alias

    # 显示使用说明
    show_usage

    # 询问是否立即运行
    echo
    read -p "是否立即启动部署管理器? [Y/n]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        run_deployer
    else
        echo
        print_success "安装完成，稍后运行: hcp-deploy"
    fi
}

# 执行主程序
main "$@"
