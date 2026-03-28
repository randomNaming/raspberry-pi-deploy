#!/bin/bash
# =============================================================================
# 快照与回滚模块
# 管理系统快照的创建、恢复和列表
# =============================================================================

# -----------------------------------------------
# 创建系统快照
# -----------------------------------------------
create_snapshot() {
    local snapshot_id
    snapshot_id=$(get_timestamp)
    local snapshot_dir="${BACKUP_DIR}/${snapshot_id}"

    mkdir -p "$snapshot_dir"

    # 备份配置目录
    if [ -d "$APP_DIR/config" ]; then
        cp -r "$APP_DIR/config" "$snapshot_dir/"
    fi

    # 备份JAR文件
    if [ -f "$APP_DIR/${JAR_FILE}" ]; then
        cp "$APP_DIR/${JAR_FILE}" "$snapshot_dir/"
    fi

    # 备份systemd服务文件
    if [ -f "/etc/systemd/system/${SERVICE_NAME}" ]; then
        cp "/etc/systemd/system/${SERVICE_NAME}" "$snapshot_dir/"
    fi

    # 保存快照ID
    echo "$snapshot_id" > "$snapshot_dir/id"

    update_state "SNAPSHOT_BEFORE" "$snapshot_id"
    print_info "快照已创建: $snapshot_id"

    echo "$snapshot_id"
}

# -----------------------------------------------
# 回滚到指定快照
# -----------------------------------------------
rollback_to() {
    local snapshot_id="${1:-}"

    if [ -z "$snapshot_id" ]; then
        print_error "未提供快照ID"
        return 1
    fi

    local snapshot_dir="${BACKUP_DIR}/${snapshot_id}"

    if [ ! -d "$snapshot_dir" ]; then
        print_error "快照不存在: $snapshot_id"
        return 1
    fi

    print_step "回滚到快照: $snapshot_id"

    # 停止服务
    run_as_root systemctl stop "${APP_NAME}" 2>/dev/null || true

    # 恢复配置
    if [ -d "$snapshot_dir/config" ]; then
        mkdir -p "$APP_DIR/config"
        cp -r "$snapshot_dir/config/"* "$APP_DIR/config/" 2>/dev/null || true
    fi

    # 恢复JAR文件
    if [ -f "$snapshot_dir/${JAR_FILE}" ]; then
        cp "$snapshot_dir/${JAR_FILE}" "$APP_DIR/" 2>/dev/null || true
    fi

    # 恢复systemd服务文件
    if [ -f "$snapshot_dir/${SERVICE_NAME}" ]; then
        run_as_root cp "$snapshot_dir/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"
        run_as_root systemctl daemon-reload
    fi

    # 重启服务
    run_as_root systemctl start "${APP_NAME}" 2>/dev/null || true

    print_success "回滚完成"
}

# -----------------------------------------------
# 列出所有可用快照
# -----------------------------------------------
list_snapshots() {
    echo
    print_info "可用快照:"

    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        print_warn "没有可用的快照"
        return
    fi

    printf "\n%-20s %-25s %s\n" "快照ID" "创建时间" "内容"
    printf "%-20s %-25s %s\n" "------" "------" "------"

    for dir in "$BACKUP_DIR"/*; do
        if [ -d "$dir" ]; then
            local id created contents
            id=$(basename "$dir")
            created=$(stat -c %y "$dir" 2>/dev/null | cut -d' ' -f1,2 || echo "未知")
            contents=""
            [ -d "$dir/config" ] && contents="${contents}配置 "
            [ -f "$dir/${JAR_FILE}" ] && contents="${contents}JAR "
            [ -f "$dir/${SERVICE_NAME}" ] && contents="${contents}服务"
            printf "%-20s %-25s %s\n" "$id" "$created" "$contents"
        fi
    done
}

# -----------------------------------------------
# 回滚提示（在部署失败时使用）
# -----------------------------------------------
rollback_prompt() {
    local snapshot_id="$1"

    echo
    if confirm "回滚到之前的状态?" "y"; then
        rollback_to "$snapshot_id"
    else
        print_warn "未执行回滚，系统可能处于不一致状态"
    fi
}

# -----------------------------------------------
# 扫描当前安装状态
# -----------------------------------------------
scan_installation() {
    print_step "扫描当前安装"
    detect_installation

    echo
    print_info "已配置的桩:"
    if [ -f "$APP_DIR/config/application.yml" ]; then
        grep "pile-code:" "$APP_DIR/config/application.yml" | awk '{print "  - " $2}' | tr -d '"'
    fi

    echo
    print_info "服务状态:"
    run_as_root systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true
}

# -----------------------------------------------
# 备份当前状态
# -----------------------------------------------
backup_current() {
    print_step "备份当前状态"

    local snapshot_id
    snapshot_id=$(create_snapshot)
    print_success "快照已创建: $snapshot_id"

    # 创建完整备份压缩包
    local backup_file="${HOME}/hcp-backup-$(get_timestamp).tar.gz"

    tar -czf "$backup_file" \
        -C "$APP_DIR" . \
        -C "$(dirname "$STATE_FILE")" .hcp-deploy-state \
        "/etc/systemd/system/${SERVICE_NAME}" 2>/dev/null || true

    print_success "完整备份: $backup_file"
}

# -----------------------------------------------
# 仅更新应用（不动配置）
# -----------------------------------------------
update_app_only() {
    print_step "仅更新应用"

    # 停止服务
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_info "停止服务..."
        run_as_root systemctl stop "${SERVICE_NAME}"
    fi

    # 部署新的JAR
    deploy_jar

    # 启动服务
    print_info "启动服务..."
    run_as_root systemctl start "${SERVICE_NAME}"
}

# -----------------------------------------------
# 重置配置为默认值
# -----------------------------------------------
reset_config() {
    print_step "重置配置"

    echo
    echo "  [1] 重置应用配置"
    echo "  [2] 重置 WireGuard 配置"
    echo "  [3] 重置全部配置"
    echo "  [0] 取消"
    echo

    local choice
    safe_read_char "选择 [0-3]" choice

    case $choice in
        1)
            if confirm "重置应用配置为默认值?" "n"; then
                create_snapshot
                create_default_config
                print_success "应用配置已重置为默认值"
                print_info "请使用配置管理重新配置"
            fi
            ;;
        2)
            reset_wireguard_config
            ;;
        3)
            if confirm "重置全部配置（应用 + WireGuard）?" "n"; then
                create_snapshot
                create_default_config
                print_success "应用配置已重置为默认值"
                reset_wireguard_config
                print_success "全部配置已重置"
            fi
            ;;
        0)
            print_info "已取消"
            ;;
        *)
            print_error "无效选择"
            ;;
    esac
}

# -----------------------------------------------
# 重置 WireGuard 配置
# -----------------------------------------------
reset_wireguard_config() {
    print_step "重置 WireGuard 配置"

    if ! is_wireguard_installed; then
        print_warn "WireGuard 未安装"
        return 1
    fi

    # 停止 WireGuard 服务
    if is_wireguard_running; then
        print_info "停止 WireGuard 服务..."
        run_as_root systemctl stop wg-quick@wg0 2>/dev/null || true
    fi

    # 备份现有配置
    local backup_file="${BACKUP_DIR}/wg0.conf.$(get_timestamp)"
    if [ -f "$WG_CONF_FILE" ]; then
        run_as_root cp "$WG_CONF_FILE" "$backup_file" 2>/dev/null || true
        print_info "配置已备份: $backup_file"
    fi

    # 删除配置文件
    run_as_root rm -f "$WG_CONF_FILE" 2>/dev/null || true

    # 生成新的密钥对
    print_info "生成新的密钥对..."
    local private_key public_key
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        print_error "密钥生成失败"
        return 1
    fi

    # 保存密钥
    run_as_root mkdir -p "$WG_CONF_DIR"
    echo "$private_key" | run_as_root tee "${WG_CONF_DIR}/pi_private.key" > /dev/null
    echo "$public_key" | run_as_root tee "${WG_CONF_DIR}/pi_public.key" > /dev/null
    run_as_root chmod 600 "${WG_CONF_DIR}/pi_private.key"
    run_as_root chmod 644 "${WG_CONF_DIR}/pi_public.key"

    # 获取VPN IP
    local vpn_ip="10.0.0.2"
    if [[ -t 0 ]]; then
        vpn_ip=$(safe_read "本机 VPN IP (如 10.0.0.2)" "10.0.0.2")
    fi

    print_success "WireGuard 配置已重置"

    # 显示需要添加到服务器的Peer配置
    echo
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  请将以下配置添加到服务器${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo
    echo -e "  服务器配置文件位置: ${GREEN}/etc/wireguard/wg0.conf${NC}"
    echo
    echo -e "  请在服务器上执行: ${GREEN}sudo nano /etc/wireguard/wg0.conf${NC}"
    echo
    echo -e "  在文件末尾添加以下内容:"
    echo
    echo -e "${CYAN}# 树莓派 $(hostname)${NC}"
    echo -e "${CYAN}[Peer]${NC}"
    echo -e "${CYAN}PublicKey = ${public_key}${NC}"
    echo -e "${CYAN}AllowedIPs = ${vpn_ip}/32${NC}"
    echo
    echo -e "  添加后，执行: ${GREEN}sudo systemctl restart wg-quick@wg0${NC}"
    echo
}

# -----------------------------------------------
# 完全重新安装
# -----------------------------------------------
full_reinstall() {
    print_step "完全重装"

    print_warn "这将重新安装所有内容!"
    if ! confirm "继续完全重装?" "n"; then
        return
    fi

    # 先备份
    backup_current

    # 停止并禁用服务
    run_as_root systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    run_as_root systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

    # 移除服务文件
    run_as_root rm -f "/etc/systemd/system/${SERVICE_NAME}"
    run_as_root systemctl daemon-reload

    # 执行全新部署
    auto_deploy
}

# -----------------------------------------------
# 从备份恢复
# -----------------------------------------------
restore_backup() {
    print_step "从备份恢复"

    list_snapshots
    echo

    local snapshot_id
    snapshot_id=$(safe_read "输入快照ID进行恢复" "")
    if [ -n "$snapshot_id" ]; then
        rollback_to "$snapshot_id"
    fi
}

# -----------------------------------------------
# 镜像接管菜单
# -----------------------------------------------
image_takeover() {
    print_header "镜像接管模式"
    print_info "用于重新部署现有环境"
    echo

    local options=(
        "扫描当前安装"
        "备份当前状态"
        "仅更新应用"
        "重置配置"
        "完全重装"
        "从备份恢复"
        "返回主菜单"
    )

    for i in "${!options[@]}"; do
        printf "  [%d] %s\n" $((i+1)) "${options[$i]}"
    done

    echo
    local choice
    local choice
    safe_read_char "选择 [1-${#options[@]}]" choice
    echo

    case $choice in
        1) scan_installation ;;
        2) backup_current ;;
        3) update_app_only ;;
        4) reset_config ;;
        5) full_reinstall ;;
        6) restore_backup ;;
        7) return 0 ;;
        *)
            if [ -n "$choice" ]; then
                print_error "无效选择"
            fi
            ;;
    esac
}
