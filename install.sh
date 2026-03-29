#!/bin/bash
# =============================================================================
# HCP Simulator Lite - 一键安装引导脚本
#
# 使用方式：
#   # Gitee (国内用户)
#   bash <(curl -sL https://gitee.com/garrettxia/raspberry-pi-deploy/raw/main/install.sh)
#
#   # GitHub (海外用户)
#   bash <(curl -sL https://raw.githubusercontent.com/randomNaming/raspberry-pi-deploy/main/install.sh)
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
    for cmd in curl bash; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_error "缺少必要依赖: ${missing[*]}"
        exit 1
    fi
}

# -----------------------------------------------
# 获取远程版本号
# -----------------------------------------------
get_remote_version() {
    local source="$1"
    local version_url=""
    local version=""

    if [ "$source" = "gitee" ]; then
        version_url="https://gitee.com/${GITEE_USER}/${REPO_NAME}/raw/${BRANCH}/lib/common.sh?t=${CACHE_BUST}"
    else
        version_url="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/${BRANCH}/lib/common.sh?t=${CACHE_BUST}"
    fi

    version=$(curl -sL --connect-timeout 10 --max-time 15 "$version_url" 2>/dev/null | grep "SCRIPT_VERSION" | cut -d'"' -f2)
    echo "$version"
}

# -----------------------------------------------
# 获取本地版本号
# -----------------------------------------------
get_local_version() {
    if [ -f "$INSTALL_DIR/lib/common.sh" ]; then
        grep "SCRIPT_VERSION" "$INSTALL_DIR/lib/common.sh" 2>/dev/null | cut -d'"' -f2
    fi
}

# -----------------------------------------------
# 检测可用的源
# -----------------------------------------------
detect_source() {
    print_info "检测可用源..."

    # 测试 Gitee
    if curl -sL --connect-timeout 5 --max-time 8 "https://gitee.com" -o /dev/null 2>/dev/null; then
        echo "gitee"
        return
    fi

    # 测试 GitHub
    if curl -sL --connect-timeout 5 --max-time 8 "https://raw.githubusercontent.com" -o /dev/null 2>/dev/null; then
        echo "github"
        return
    fi

    echo ""
}

# -----------------------------------------------
# 下载单个文件
# -----------------------------------------------
download_file() {
    local url="$1"
    local output="$2"

    if curl -sL --connect-timeout 15 --max-time 60 "$url" -o "$output" 2>/dev/null; then
        if [ -s "$output" ]; then
            return 0
        fi
    fi
    return 1
}

# -----------------------------------------------
# 下载项目（逐文件方式，更可靠）
# -----------------------------------------------
download_by_files() {
    local source="$1"
    local base_url=""

    if [ "$source" = "gitee" ]; then
        base_url="https://gitee.com/${GITEE_USER}/${REPO_NAME}/raw/${BRANCH}"
    else
        base_url="https://raw.githubusercontent.com/${GITHUB_USER}/${REPO_NAME}/${BRANCH}"
    fi

    print_info "逐文件下载..."

    mkdir -p "$TEMP_DIR/lib"

    # 下载主脚本
    if ! download_file "${base_url}/deploy-interactive.sh?t=${CACHE_BUST}" "$TEMP_DIR/deploy-interactive.sh"; then
        return 1
    fi

    # 下载引导脚本（用于更新）
    download_file "${base_url}/install.sh?t=${CACHE_BUST}" "$TEMP_DIR/install.sh" 2>/dev/null || true

    # 下载 lib 目录下的所有脚本
    local lib_files=(
        "common.sh"
        "state.sh"
        "env-check.sh"
        "mirror.sh"
        "download.sh"
        "install.sh"
        "wireguard.sh"
        "config.sh"
        "service.sh"
        "snapshot.sh"
        "resume.sh"
    )

    for file in "${lib_files[@]}"; do
        if ! download_file "${base_url}/lib/${file}?t=${CACHE_BUST}" "$TEMP_DIR/lib/${file}"; then
            print_warn "下载失败: lib/${file}"
            return 1
        fi
    done

    return 0
}

# -----------------------------------------------
# 下载项目（压缩包方式）
# -----------------------------------------------
download_by_archive() {
    local source="$1"
    local archive_url=""

    if [ "$source" = "gitee" ]; then
        archive_url="https://gitee.com/${GITEE_USER}/${REPO_NAME}/repository/archive/${BRANCH}?t=${CACHE_BUST}"
    else
        archive_url="https://github.com/${GITHUB_USER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.tar.gz?t=${CACHE_BUST}"
    fi

    print_info "下载压缩包..."

    mkdir -p "$TEMP_DIR"

    if download_file "$archive_url" "$TEMP_DIR/archive.tar.gz"; then
        if tar xzf "$TEMP_DIR/archive.tar.gz" -C "$TEMP_DIR" --strip-components=1 2>/dev/null; then
            rm -f "$TEMP_DIR/archive.tar.gz"
            return 0
        fi
    fi

    rm -f "$TEMP_DIR/archive.tar.gz"
    return 1
}

# -----------------------------------------------
# 下载项目（主函数）
# -----------------------------------------------
download_project() {
    local source="${1:-}"
    print_step "下载项目文件..."

    # 如果没有指定源，自动检测
    if [ -z "$source" ]; then
        source=$(detect_source)
        if [ -z "$source" ]; then
            print_error "无法连接到任何源，请检查网络"
            exit 1
        fi
        print_success "使用源: $source"
    fi

    # 方式1: 尝试压缩包下载
    if download_by_archive "$source"; then
        # 验证关键文件
        if [ -f "$TEMP_DIR/deploy-interactive.sh" ] && [ -d "$TEMP_DIR/lib" ]; then
            print_success "下载完成 (压缩包方式)"
            return 0
        fi
    fi

    # 方式2: 尝试逐文件下载
    print_warn "压缩包下载失败，尝试逐文件下载..."
    rm -rf "$TEMP_DIR"/*

    if download_by_files "$source"; then
        if [ -f "$TEMP_DIR/deploy-interactive.sh" ] && [ -d "$TEMP_DIR/lib" ]; then
            print_success "下载完成 (逐文件方式)"
            return 0
        fi
    fi

    # 如果当前源失败，尝试另一个源
    local other_source=""
    if [ "$source" = "gitee" ]; then
        other_source="github"
    else
        other_source="gitee"
    fi

    print_warn "当前源失败，尝试 $other_source..."
    rm -rf "$TEMP_DIR"/*

    if download_by_archive "$other_source" || download_by_files "$other_source"; then
        if [ -f "$TEMP_DIR/deploy-interactive.sh" ] && [ -d "$TEMP_DIR/lib" ]; then
            print_success "下载完成 (备用源: $other_source)"
            return 0
        fi
    fi

    print_error "所有下载方式均失败"
    exit 1
}

# -----------------------------------------------
# 安装到本地
# -----------------------------------------------
install_local() {
    print_step "安装部署工具..."

    # 清理旧版本
    if [ -d "$INSTALL_DIR" ]; then
        print_info "清理旧版本..."
        rm -rf "$INSTALL_DIR"
    fi

    # 创建安装目录
    mkdir -p "$INSTALL_DIR"

    # 复制文件
    cp -r "$TEMP_DIR"/* "$INSTALL_DIR/"

    # 设置执行权限
    chmod +x "$INSTALL_DIR/deploy-interactive.sh"
    chmod +x "$INSTALL_DIR"/lib/*.sh 2>/dev/null || true
    [ -f "$INSTALL_DIR/install.sh" ] && chmod +x "$INSTALL_DIR/install.sh" || true

    local version
    version=$(get_local_version)
    print_success "安装完成: $INSTALL_DIR (版本: ${version:-未知})"
}

# -----------------------------------------------
# 创建快捷命令
# -----------------------------------------------
create_alias() {
    # 清理旧的 bashrc 别名
    if [ -f "${HOME}/.bashrc" ]; then
        sed -i '/hcp-deploy\|hcp-update\|HCP Simulator/d' "${HOME}/.bashrc" 2>/dev/null || true
    fi

    # 创建 hcp-deploy 命令
    local deploy_cmd="#!/bin/bash
exec bash \"${INSTALL_DIR}/deploy-interactive.sh\" \"\$@\""

    # 创建 hcp-update 命令（自包含，不依赖本地文件）
    local update_cmd='#!/bin/bash
GITEE_URL="https://gitee.com/garrettxia/raspberry-pi-deploy/raw/main/install.sh?t=$(date +%s)"
GITHUB_URL="https://raw.githubusercontent.com/randomNaming/raspberry-pi-deploy/main/install.sh?t=$(date +%s)"

# 尝试 Gitee
if curl -sL --connect-timeout 10 --max-time 5 "$GITEE_URL" 2>/dev/null | head -1 | grep -q "^#!/"; then
    bash <(curl -sL "$GITEE_URL") "$@"
    exit 0
fi

# Gitee 失败，尝试 GitHub
if curl -sL --connect-timeout 10 --max-time 5 "$GITHUB_URL" 2>/dev/null | head -1 | grep -q "^#!/"; then
    bash <(curl -sL "$GITHUB_URL") "$@"
    exit 0
fi

echo "[错误] 无法下载更新脚本，请检查网络连接"
echo "手动执行: bash <(curl -sL $GITEE_URL)"
exit 1'

    # 优先创建到 /usr/local/bin/
    if [ -d "/usr/local/bin" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            echo "$deploy_cmd" > /usr/local/bin/hcp-deploy
            echo "$update_cmd" > /usr/local/bin/hcp-update
            chmod +x /usr/local/bin/hcp-deploy /usr/local/bin/hcp-update
            print_info "命令已创建: /usr/local/bin/hcp-deploy"
            print_info "命令已创建: /usr/local/bin/hcp-update"
            return 0
        elif command -v sudo &>/dev/null; then
            echo "$deploy_cmd" | sudo tee /usr/local/bin/hcp-deploy > /dev/null
            echo "$update_cmd" | sudo tee /usr/local/bin/hcp-update > /dev/null
            sudo chmod +x /usr/local/bin/hcp-deploy /usr/local/bin/hcp-update
            print_info "命令已创建: /usr/local/bin/hcp-deploy"
            print_info "命令已创建: /usr/local/bin/hcp-update"
            return 0
        fi
    fi

    # 降级方案: 创建到 ~/bin/
    mkdir -p "${HOME}/bin"
    echo "$deploy_cmd" > "${HOME}/bin/hcp-deploy"
    echo "$update_cmd" > "${HOME}/bin/hcp-update"
    chmod +x "${HOME}/bin/hcp-deploy" "${HOME}/bin/hcp-update"

    # 确保 ~/bin 在 PATH 中
    if [[ ":$PATH:" != *":${HOME}/bin:"* ]]; then
        echo 'export PATH="${HOME}/bin:${PATH}"' >> "${HOME}/.bashrc"
        print_info "已添加 ~/bin 到 PATH，请执行: source ~/.bashrc"
    fi

    print_info "命令已创建: ${HOME}/bin/hcp-deploy"
    print_info "命令已创建: ${HOME}/bin/hcp-update"
}

# -----------------------------------------------
# 显示使用说明
# -----------------------------------------------
show_usage() {
    local version
    version=$(get_local_version)

    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  HCP Simulator Lite 安装完成${NC}"
    echo -e "${BLUE}  版本: ${version}${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    echo "运行命令: hcp-deploy"
    echo "更新命令: hcp-update"
    echo
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
# 主程序
# -----------------------------------------------
main() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  HCP Simulator Lite${NC}"
    echo -e "${BLUE}  安装/更新程序${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo

    # 检查依赖
    check_deps

    # 检查本地版本
    local local_version
    local_version=$(get_local_version)

    if [ -n "$local_version" ]; then
        print_info "当前本地版本: $local_version"
    fi

    # 选择下载源
    local source="${1:-}"
    if [ -z "$source" ]; then
        echo "  选择下载源:"
        echo "  [1] 自动检测 (推荐)"
        echo "  [2] Gitee (国内)"
        echo "  [3] GitHub (海外)"
        echo
        read -p "选择 [1-3]: " -n 1 -r choice || choice="1"
        echo

        case $choice in
            2) source="gitee" ;;
            3) source="github" ;;
            *) source="" ;;  # 自动检测
        esac
    fi

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
        print_success "安装完成，运行: hcp-deploy"
    fi
}

# 执行主程序
main "$@"
