#!/bin/bash
# =============================================================================
# HCP Simulator Lite - 一键安装引导脚本
#
# 使用方式：
#   # GitHub (海外用户)
#   bash <(curl -sL https://raw.githubusercontent.com/randomNaming/raspberry-pi-deploy/main/install.sh)
#
#   # Gitee (国内用户，更快更稳定)
#   bash <(curl -sL https://gitee.com/randomNaming/raspberry-pi-deploy/raw/main/install.sh)
#
# 功能：下载完整项目并启动部署管理器
# =============================================================================

set -uo pipefail

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
readonly GITHUB_USER="randomNaming"
readonly GITEE_USER="garrettxia"
readonly REPO_NAME="raspberry-pi-deploy"
readonly BRANCH="main"
readonly INSTALL_DIR="${HOME}/.hcp-deploy"
readonly TEMP_DIR="/tmp/hcp-deploy-setup-$$"
readonly CACHE_BUST=$(date +%s)

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
# 测试源连通性
# -----------------------------------------------
test_source() {
    local url="$1"
    local timeout="${2:-5}"
    curl -sL --connect-timeout "$timeout" --max-time "$timeout" "$url" -o /dev/null 2>/dev/null
}

# -----------------------------------------------
# 选择下载源
# -----------------------------------------------
select_source() {
    local source="${1:-}"

    # 如果指定了源，直接使用
    if [ -n "$source" ]; then
        echo "$source"
        return
    fi

    print_step "选择下载源"
    echo
    echo "  [1] Gitee (国内推荐，速度快)"
    echo "  [2] GitHub (海外用户)"
    echo "  [3] 自动检测"
    echo

    read -p "选择 [1-3]: " -n 1 -r choice || choice="3"
    echo

    case $choice in
        1)
            echo "gitee"
            return
            ;;
        2)
            echo "github"
            return
            ;;
        *)
            # 自动检测
            print_info "自动检测最佳源..."
            if test_source "https://gitee.com" 3; then
                print_success "Gitee 连通，使用 Gitee 源"
                echo "gitee"
            elif test_source "https://github.com" 5; then
                print_success "GitHub 连通，使用 GitHub 源"
                echo "github"
            else
                print_warn "自动检测失败，默认使用 Gitee"
                echo "gitee"
            fi
            return
            ;;
    esac
}

# -----------------------------------------------
# 下载项目
# -----------------------------------------------
download_project() {
    local source="$1"
    print_step "下载项目文件..."

    mkdir -p "$TEMP_DIR"

    local archive_url=""
    local success=false

    if [ "$source" = "gitee" ]; then
        # Gitee 下载地址（添加时间戳避免缓存）
        archive_url="https://gitee.com/${GITEE_USER}/${REPO_NAME}/repository/archive/${BRANCH}?t=${CACHE_BUST}"
        print_info "从 Gitee 下载..."

        if curl -sL --connect-timeout 10 --max-time 120 "$archive_url" -o "$TEMP_DIR/archive.tar.gz" 2>/dev/null; then
            # Gitee 的 tar 包格式略有不同
            if tar xzf "$TEMP_DIR/archive.tar.gz" -C "$TEMP_DIR" --strip-components=1 2>/dev/null; then
                success=true
            fi
            rm -f "$TEMP_DIR/archive.tar.gz"
        fi

        # 如果 Gitee 失败，尝试 GitHub
        if [ "$success" = false ]; then
            print_warn "Gitee 下载失败，尝试 GitHub..."
            source="github"
        fi
    fi

    if [ "$source" = "github" ]; then
        # GitHub 下载地址（添加时间戳避免缓存）
        archive_url="https://github.com/${GITHUB_USER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.tar.gz?t=${CACHE_BUST}"
        print_info "从 GitHub 下载..."

        if curl -sL --connect-timeout 10 --max-time 120 "$archive_url" | tar xz -C "$TEMP_DIR" --strip-components=1 2>/dev/null; then
            success=true
        fi
    fi

    # 验证下载结果
    if [ "$success" = false ] || [ ! -f "$TEMP_DIR/deploy-interactive.sh" ]; then
        print_error "下载失败，请检查网络连接"
        print_info "可手动下载后放置到: $INSTALL_DIR"
        exit 1
    fi

    if [ ! -d "$TEMP_DIR/lib" ]; then
        print_error "下载不完整，未找到 lib 目录"
        exit 1
    fi

    print_success "项目下载完成 (来源: $source)"
}

# -----------------------------------------------
# 安装到本地
# -----------------------------------------------
install_local() {
    print_step "安装部署工具..."

    # 清理旧版本
    if [ -d "$INSTALL_DIR" ]; then
        print_info "检测到旧版本，正在更新..."
        rm -rf "$INSTALL_DIR"
    fi

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
    echo -e "${BLUE}  HCP Simulator Lite 安装完成${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    echo "快捷命令运行："
    echo
    echo "  hcp-deploy"
    echo
    echo "或直接运行："
    echo
    echo "  bash ~/.hcp-deploy/deploy-interactive.sh"
    echo
    echo "更新命令："
    echo
    echo "  # Gitee 源"
    echo "  rm -rf ~/.hcp-deploy && bash <(curl -sL https://gitee.com/${GITEE_USER}/${REPO_NAME}/raw/main/install.sh)"
    echo
    echo "  # GitHub 源"
    echo "  rm -rf ~/.hcp-deploy && bash <(curl -sL https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/main/install.sh)"
    echo
}

# -----------------------------------------------
# 创建快捷命令
# -----------------------------------------------
create_alias() {
    local alias_file="${HOME}/.bashrc"

    # 移除旧别名（如果存在）
    if grep -q "hcp-deploy" "$alias_file" 2>/dev/null; then
        sed -i '/hcp-deploy/d' "$alias_file" 2>/dev/null || true
    fi

    # 添加新别名
    cat >> "$alias_file" << EOF

# HCP Simulator Lite 部署工具
alias hcp-deploy='bash ~/.hcp-deploy/deploy-interactive.sh'
alias hcp-update='rm -rf ~/.hcp-deploy && bash <(curl -sL https://gitee.com/${GITEE_USER}/${REPO_NAME}/raw/main/install.sh)'
EOF

    print_info "已添加快捷命令:"
    print_info "  hcp-deploy  - 运行部署工具"
    print_info "  hcp-update  - 一键更新"
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

    # 选择下载源
    local source
    source=$(select_source "${1:-}")

    # 下载项目
    download_project "$source"

    # 安装到本地
    install_local

    # 创建快捷命令
    create_alias

    # 显示使用说明
    show_usage

    # 询问是否立即运行
    echo
    read -p "是否立即启动部署管理器? [Y/n]: " -n 1 -r || REPLY="Y"
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
