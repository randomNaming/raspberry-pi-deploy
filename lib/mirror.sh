#!/bin/bash
# =============================================================================
# 镜像源管理模块
# 处理国内镜像源更换、软件源更新等
# =============================================================================

# -----------------------------------------------
# 更换软件源（国内镜像加速）
# -----------------------------------------------
change_mirror() {
    print_step "更换软件源"

    # 检测是否需要更换
    if [ -f /etc/apt/sources.list ]; then
        if grep -q "mirrors.aliyun.com\|mirrors.tuna.tsinghua.edu.cn\|mirrors.ustc.edu.cn" /etc/apt/sources.list 2>/dev/null; then
            print_info "已使用国内镜像源，无需更换"
            return 0
        fi
    fi

    # 检测系统版本
    local os_id="" os_codename=""
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        os_id="${ID:-}"
        os_codename="${VERSION_CODENAME:-}"
    fi

    # 获取代号（兼容不同方式）
    if [ -z "$os_codename" ] && [ -f /etc/lsb-release ]; then
        os_codename=$(grep "DISTRIB_CODENAME" /etc/lsb-release | cut -d'=' -f2)
    fi
    if [ -z "$os_codename" ]; then
        os_codename=$(lsb_release -cs 2>/dev/null || echo "")
    fi

    if [ -z "$os_codename" ]; then
        print_warn "无法检测系统代号，跳过换源"
        return 0
    fi

    print_info "检测到系统: ${os_id} ${os_codename}"

    # 选择镜像源
    local mirror_url=""
    echo
    echo "  选择镜像源:"
    echo "  [1] 阿里云 (推荐)"
    echo "  [2] 清华大学"
    echo "  [3] 中科大"
    echo "  [4] 跳过换源"
    echo

    local choice
    safe_read_char "选择 [1-4]" choice "1"

    case $choice in
        1) mirror_url="https://mirrors.aliyun.com" ;;
        2) mirror_url="https://mirrors.tuna.tsinghua.edu.cn" ;;
        3) mirror_url="https://mirrors.ustc.edu.cn" ;;
        4|*)
            print_info "跳过换源"
            return 0
            ;;
    esac

    # 备份原配置
    local backup_file="/etc/apt/sources.list.bak.$(get_timestamp)"
    print_info "备份原配置: $backup_file"
    run_as_root cp /etc/apt/sources.list "$backup_file" 2>/dev/null || true

    # 生成新配置
    local new_sources=""

    if [ "$os_id" = "ubuntu" ]; then
        # Ubuntu源
        new_sources=$(cat << EOF
deb ${mirror_url}/ubuntu/ ${os_codename} main restricted universe multiverse
deb ${mirror_url}/ubuntu/ ${os_codename}-updates main restricted universe multiverse
deb ${mirror_url}/ubuntu/ ${os_codename}-backports main restricted universe multiverse
deb ${mirror_url}/ubuntu/ ${os_codename}-security main restricted universe multiverse
EOF
)
    elif [ "$os_id" = "debian" ] || [ "$os_id" = "raspbian" ]; then
        # Debian源
        new_sources=$(cat << EOF
deb ${mirror_url}/debian/ ${os_codename} main contrib non-free non-free-firmware
deb ${mirror_url}/debian/ ${os_codename}-updates main contrib non-free non-free-firmware
deb ${mirror_url}/debian-security/ ${os_codename}-security main contrib non-free non-free-firmware
EOF
)
    else
        print_warn "不支持的系统: ${os_id}，跳过换源"
        return 0
    fi

    # 写入新配置
    echo "$new_sources" | run_as_root tee /etc/apt/sources.list > /dev/null
    print_success "软件源已更换为: ${mirror_url}"

    return 0
}

# -----------------------------------------------
# 更新软件源
# -----------------------------------------------
update_apt() {
    print_info "更新软件源..."
    if run_as_root apt update 2>&1; then
        print_success "软件源更新成功"
        return 0
    else
        print_error "软件源更新失败"
        print_info "建议执行换源操作或检查网络连接"
        return 1
    fi
}
