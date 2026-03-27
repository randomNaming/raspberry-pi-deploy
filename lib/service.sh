#!/bin/bash
# =============================================================================
# 服务管理模块
# 管理systemd服务的生命周期
# =============================================================================

# -----------------------------------------------
# 服务状态显示
# -----------------------------------------------
service_status() {
    echo
    sudo systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true
}

# -----------------------------------------------
# 启动服务
# -----------------------------------------------
service_start() {
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_warn "服务已在运行"
        return
    fi

    sudo systemctl start "${SERVICE_NAME}"
    sleep 2

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_success "服务已启动"
    else
        print_error "服务启动失败"
        print_info "查看日志: sudo journalctl -u ${SERVICE_NAME} -n 30"
    fi
}

# -----------------------------------------------
# 停止服务
# -----------------------------------------------
service_stop() {
    if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_warn "服务未运行"
        return
    fi

    if confirm "停止服务?" "y"; then
        sudo systemctl stop "${SERVICE_NAME}"
        print_success "服务已停止"
    fi
}

# -----------------------------------------------
# 重启服务
# -----------------------------------------------
service_restart() {
    print_info "重启服务..."
    sudo systemctl restart "${SERVICE_NAME}"
    sleep 3

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_success "服务已重启"
    else
        print_error "服务重启失败"
    fi
}

# -----------------------------------------------
# 实时查看服务日志
# -----------------------------------------------
service_logs_live() {
    print_info "按Ctrl+C退出日志查看"
    sudo journalctl -u "${SERVICE_NAME}" -f
}

# -----------------------------------------------
# 查看最近的服务日志
# -----------------------------------------------
service_logs_recent() {
    local lines=${1:-50}
    sudo journalctl -u "${SERVICE_NAME}" -n "$lines"
}

# -----------------------------------------------
# 启用开机自启
# -----------------------------------------------
service_enable() {
    sudo systemctl enable "${SERVICE_NAME}"
    print_success "服务已启用开机启动"
}

# -----------------------------------------------
# 禁用开机自启
# -----------------------------------------------
service_disable() {
    sudo systemctl disable "${SERVICE_NAME}"
    print_success "服务已禁用开机启动"
}

# -----------------------------------------------
# 服务管理菜单
# -----------------------------------------------
service_menu() {
    while true; do
        echo
        print_header "服务管理"
        echo

        # 显示当前服务状态
        local status_text="未知"
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            status_text="${GREEN}运行中${NC}"
        else
            status_text="${RED}已停止${NC}"
        fi

        echo -e "  服务状态: $status_text"
        echo

        local options=(
            "查看状态"
            "启动服务"
            "停止服务"
            "重启服务"
            "查看日志(实时)"
            "查看最近日志"
            "启用开机启动"
            "禁用开机启动"
            "返回主菜单"
        )

        for i in "${!options[@]}"; do
            printf "  [%d] %s\n" $((i+1)) "${options[$i]}"
        done

        echo
        local choice
        choice=$(safe_read_char "选择 [1-${#options[@]}]" "")
        echo

        case $choice in
            1) service_status ;;
            2) service_start ;;
            3) service_stop ;;
            4) service_restart ;;
            5) service_logs_live ;;
            6) service_logs_recent ;;
            7) service_enable ;;
            8) service_disable ;;
            9) return 0 ;;
            *)
                if [ -n "$choice" ]; then
                    print_error "无效选择"
                fi
                ;;
        esac

        # 非交互环境下自动退出
        if [[ ! -t 0 ]]; then
            return 0
        fi

        pause
    done
}
