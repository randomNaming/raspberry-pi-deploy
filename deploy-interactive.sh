#!/bin/bash
# =============================================================================
# HCP Simulator Lite - 交互式部署管理器
# 适用于树莓派4B (Raspberry Pi OS 64-bit)
#
# 使用方法：
#   chmod +x deploy-interactive.sh
#   ./deploy-interactive.sh
#
# 项目结构：
#   deploy-interactive.sh  - 主入口脚本
#   lib/
#     common.sh            - 通用工具函数
#     state.sh             - 状态管理
#     env-check.sh         - 环境检测
#     install.sh           - 安装部署
#     config.sh            - 配置管理
#     service.sh           - 服务管理
#     snapshot.sh          - 快照与回滚
#     resume.sh            - 继续部署
# =============================================================================

set -uo pipefail

# -----------------------------------------------
# 获取脚本目录（兼容多种执行方式）
# -----------------------------------------------
get_script_dir() {
    local source="${BASH_SOURCE[0]}"
    # 处理符号链接
    while [ -L "$source" ]; do
        local dir
        dir="$(cd -P "$(dirname "$source")" && pwd)"
        source="$(readlink "$source")"
        [[ $source != /* ]] && source="$dir/$source"
    done
    cd -P "$(dirname "$source")" && pwd
}

# 设置脚本目录
SCRIPT_DIR="$(get_script_dir)"

# -----------------------------------------------
# 加载模块库
# -----------------------------------------------
load_modules() {
    local lib_dir="$SCRIPT_DIR/lib"

    # 检查lib目录是否存在
    if [ ! -d "$lib_dir" ]; then
        echo "错误: 未找到lib目录: $lib_dir"
        exit 1
    fi

    # 按依赖顺序加载模块
    local modules=(
        "common.sh"        # 基础工具函数（最先加载）
        "state.sh"         # 状态管理
        "env-check.sh"     # 环境检测
        "install.sh"       # 安装部署
        "config.sh"        # 配置管理
        "service.sh"       # 服务管理
        "snapshot.sh"      # 快照与回滚
        "resume.sh"        # 继续部署
    )

    for module in "${modules[@]}"; do
        local module_path="$lib_dir/$module"
        if [ -f "$module_path" ]; then
            # shellcheck source=/dev/null
            source "$module_path"
        else
            echo "错误: 未找到模块: $module_path"
            exit 1
        fi
    done
}

# -----------------------------------------------
# 主菜单
# -----------------------------------------------
main_menu() {
    while true; do
        clear
        echo
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}  HCP Simulator Lite${NC}"
        echo -e "${BLUE}  交互式部署管理器${NC}"
        echo -e "${BLUE}  树莓派4B版  v${SCRIPT_VERSION}${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo

        # 显示快速状态
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            echo -e "  服务状态: ${GREEN}运行中${NC}"
        else
            echo -e "  服务状态: ${RED}已停止${NC}"
        fi

        echo -e "  应用目录: $APP_DIR"
        echo

        # 菜单选项
        echo "  [1] 一键自动部署"
        echo "  [2] 环境检测"
        echo "  [3] 手动部署"
        echo "  [4] 镜像接管"
        echo "  [5] 继续部署"
        echo "  [6] 服务管理"
        echo "  [7] 配置管理"
        echo "  [8] 回滚"
        echo "  [9] 查看日志"
        echo "  [0] 退出"
        echo

        local choice
        safe_read_char "选择 [0-9]" choice
        echo

        case $choice in
            1) auto_deploy ;;
            2) run_all_checks ;;
            3) manual_deploy ;;
            4) image_takeover ;;
            5) resume_deployment ;;
            6) service_menu ;;
            7) run_config_wizard ;;
            8) show_rollback_menu ;;
            9) view_logs ;;
            0)
                echo
                print_info "再见!"
                cleanup_temp
                exit 0
                ;;
            *)
                if [ -n "$choice" ]; then
                    print_error "无效选择"
                fi
                ;;
        esac

        # 暂停等待用户按键
        if [ "$choice" != "0" ] && [ -n "$choice" ]; then
            pause
        fi
    done
}

# -----------------------------------------------
# 回滚菜单
# -----------------------------------------------
show_rollback_menu() {
    print_header "回滚"

    list_snapshots
    echo

    if confirm "执行回滚?" "n"; then
        local snapshot_id
        snapshot_id=$(safe_read "输入快照ID" "")
        if [ -n "$snapshot_id" ]; then
            rollback_to "$snapshot_id"
        fi
    fi
}

# -----------------------------------------------
# 检测更新
# -----------------------------------------------
check_update() {
    # 检查网络可用源
    local remote_url=""

    if curl -sL --connect-timeout 3 --max-time 5 "https://gitee.com" -o /dev/null 2>/dev/null; then
        remote_url="https://gitee.com/garrettxia/raspberry-pi-deploy/raw/main/lib/common.sh?t=$(date +%s)"
    elif curl -sL --connect-timeout 3 --max-time 5 "https://raw.githubusercontent.com" -o /dev/null 2>/dev/null; then
        remote_url="https://raw.githubusercontent.com/randomNaming/raspberry-pi-deploy/main/lib/common.sh?t=$(date +%s)"
    else
        return 0  # 网络不通，跳过检测
    fi

    # 获取远程版本
    local remote_version
    remote_version=$(curl -sL --connect-timeout 5 --max-time 10 "$remote_url" 2>/dev/null | grep "SCRIPT_VERSION" | cut -d'"' -f2)

    if [ -z "$remote_version" ]; then
        return 0  # 获取失败，跳过
    fi

    # 比较版本
    if [ "$remote_version" != "$SCRIPT_VERSION" ]; then
        echo
        print_warn "发现新版本: $SCRIPT_VERSION -> $remote_version"
        if confirm "是否立即更新?" "y"; then
            echo
            print_step "正在更新..."

            # 下载安装脚本并执行
            if [ -f "$SCRIPT_DIR/install.sh" ]; then
                bash "$SCRIPT_DIR/install.sh"
            else
                bash <(curl -sL "$remote_url" | sed 's/common.sh/install.sh/' | head -1)
            fi
            exit 0
        fi
    fi
}

# -----------------------------------------------
# 清理
# -----------------------------------------------
cleanup() {
    cleanup_temp
}

# 设置退出时清理
trap cleanup EXIT

# -----------------------------------------------
# 主程序入口
# -----------------------------------------------
main() {
    # 加载模块
    load_modules

    # 初始化通用环境
    init_common

    # 初始化临时目录
    create_temp_dir

    # 显示欢迎信息
    print_header "HCP Simulator Lite 部署管理器 v${SCRIPT_VERSION}"
    print_info "目标平台: 树莓派4B (Raspberry Pi OS)"
    print_info "应用: $APP_NAME"
    echo

    # 检测更新
    check_update

    # 检查运行环境
    if ! check_root; then
        print_warn "继续执行，但建议使用普通用户"
    fi

    # 运行主菜单
    main_menu
}

# 执行主程序
main "$@"
