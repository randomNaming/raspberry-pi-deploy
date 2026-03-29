#!/bin/bash
# =============================================================================
# WireGuard VPN 模块
# 检测、安装、配置 WireGuard 客户端
#
# 参考文档：docs/RASPBERRY_PI_DEPLOYMENT_GUIDE.md
# =============================================================================

# WireGuard 默认参数
readonly WG_DEFAULT_SERVER_IP="10.0.0.1"
readonly WG_DEFAULT_PORT="51820"
readonly WG_CONF_DIR="/etc/wireguard"
readonly WG_CONF_FILE="${WG_CONF_DIR}/wg0.conf"

# -----------------------------------------------
# 检查 WireGuard 是否已安装
# -----------------------------------------------
is_wireguard_installed() {
    command_exists wg && command_exists wg-quick
}

# -----------------------------------------------
# 检查 WireGuard 服务状态
# -----------------------------------------------
is_wireguard_running() {
    systemctl is-active --quiet wg-quick@wg0 2>/dev/null
}

# -----------------------------------------------
# 获取当前 VPN IP
# -----------------------------------------------
get_vpn_ip() {
    ip addr show wg0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1
}

# -----------------------------------------------
# 检测 WireGuard 安装状态（环境检测用）
# -----------------------------------------------
check_wireguard() {
    print_step "检测 WireGuard"

    if ! is_wireguard_installed; then
        print_warn "WireGuard 未安装"
        print_info "安装命令: sudo apt install wireguard wireguard-tools -y"
        return 1
    fi

    print_success "WireGuard 已安装"

    # 检查配置文件
    if ! run_as_root test -f "$WG_CONF_FILE"; then
        print_warn "配置文件不存在（部署时可自动生成）"
        return 1
    fi
    print_info "配置文件: $WG_CONF_FILE"

    # 检查服务状态
    if is_wireguard_running; then
        print_success "WireGuard 服务: 运行中"
        local vpn_ip
        vpn_ip=$(get_vpn_ip)
        if [ -n "$vpn_ip" ]; then
            print_info "VPN IP: $vpn_ip"
        fi

        # 测试连通性
        if ping -c 1 -W 3 "$WG_DEFAULT_SERVER_IP" &>/dev/null; then
            print_success "VPN 连通性: 正常 (可达 $WG_DEFAULT_SERVER_IP)"
        else
            print_warn "VPN 连通性: 无法到达 $WG_DEFAULT_SERVER_IP"
        fi
    else
        print_warn "WireGuard 服务: 未启动"
    fi

    return 0
}

# -----------------------------------------------
# 安装 WireGuard
# -----------------------------------------------
install_wireguard() {
    print_step "安装 WireGuard"

    if is_wireguard_installed; then
        print_info "WireGuard 已安装"
        return 0
    fi

    # 更新软件源
    if ! update_apt; then
        if confirm "是否更换为国内镜像源?" "y"; then
            change_mirror
            if ! update_apt; then
                print_error "更新软件源失败"
                return 1
            fi
        else
            return 1
        fi
    fi

    # 安装
    if ! safe_exec "run_as_root apt install -y wireguard wireguard-tools" "WireGuard 安装失败"; then
        return 1
    fi

    if is_wireguard_installed; then
        print_success "WireGuard 安装完成"
        return 0
    else
        print_error "WireGuard 安装验证失败"
        return 1
    fi
}

# -----------------------------------------------
# 生成 WireGuard 密钥对
# -----------------------------------------------
generate_wireguard_keys() {
    print_step "生成密钥对"

    ensure_dir "$WG_CONF_DIR"

    # 检查是否已有密钥
    if [ -f "${WG_CONF_DIR}/pi_private.key" ] && [ -f "${WG_CONF_DIR}/pi_public.key" ]; then
        print_info "密钥对已存在"
        if ! confirm "重新生成密钥对?" "n"; then
            return 0
        fi
    fi

    # 生成密钥对
    local private_key public_key
    private_key=$(wg genkey)
    public_key=$(echo "$private_key" | wg pubkey)

    if [ -z "$private_key" ] || [ -z "$public_key" ]; then
        print_error "密钥生成失败"
        return 1
    fi

    # 保存密钥
    echo "$private_key" | run_as_root tee "${WG_CONF_DIR}/pi_private.key" > /dev/null
    echo "$public_key" | run_as_root tee "${WG_CONF_DIR}/pi_public.key" > /dev/null
    run_as_root chmod 600 "${WG_CONF_DIR}/pi_private.key"
    run_as_root chmod 644 "${WG_CONF_DIR}/pi_public.key"

    print_success "密钥对已生成"
    echo
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  请将以下信息发送给服务器管理员${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo
    echo -e "  公钥: ${GREEN}${public_key}${NC}"
    echo
    echo -e "  ${RED}重要：服务器管理员需要完成以下操作才能建立连接：${NC}"
    echo -e "  1. 编辑服务器 WireGuard 配置: ${GREEN}sudo nano /etc/wireguard/wg0.conf${NC}"
    echo -e "  2. 在文件末尾添加 [Peer] 配置段（包含上述公钥）"
    echo -e "  3. ${RED}重启 WireGuard 服务: ${GREEN}sudo systemctl restart wg-quick@wg0${NC}"
    echo

    # 保存到临时文件供后续使用
    echo "$private_key" > "$TEMP_DIR/wg-private-key"
    echo "$public_key" > "$TEMP_DIR/wg-public-key"

    return 0
}

# -----------------------------------------------
# 配置 WireGuard 客户端
# -----------------------------------------------
configure_wireguard() {
    print_step "配置 WireGuard 客户端"

    # 获取私钥
    local private_key=""
    if [ -f "$TEMP_DIR/wg-private-key" ]; then
        private_key=$(cat "$TEMP_DIR/wg-private-key")
    elif [ -f "${WG_CONF_DIR}/pi_private.key" ]; then
        private_key=$(run_as_root cat "${WG_CONF_DIR}/pi_private.key")
    else
        print_error "未找到私钥，请先生成密钥对"
        return 1
    fi

    # 交互式配置
    local vpn_ip server_pubkey server_endpoint

    echo
    echo -e "${CYAN}--- WireGuard 客户端配置 ---${NC}"
    echo

    # VPN IP
    vpn_ip=$(safe_read "本机 VPN IP (如 10.0.0.3)" "10.0.0.2")

    # 服务器公钥
    if [ -f "$TEMP_DIR/wg-server-pubkey" ]; then
        server_pubkey=$(cat "$TEMP_DIR/wg-server-pubkey")
        print_info "服务器公钥: ${server_pubkey:0:20}..."
    else
        echo
        print_info "请输入服务器管理员提供的公钥"
        server_pubkey=$(safe_read "服务器公钥" "")

        if [ -z "$server_pubkey" ]; then
            print_error "服务器公钥不能为空"
            return 1
        fi
    fi

    # 服务器地址
    local server_endpoint=""
    while [ -z "$server_endpoint" ]; do
        server_endpoint=$(safe_read "服务器地址 (IP:端口, 如 1.2.3.4:51820)" "")
        if [ -z "$server_endpoint" ]; then
            print_warn "服务器地址不能为空"
        elif ! [[ "$server_endpoint" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
            print_warn "格式错误，正确格式: IP:端口 (如 1.2.3.4:51820)"
            server_endpoint=""
        fi
    done

    # 创建配置目录
    run_as_root mkdir -p "$WG_CONF_DIR"

    # 写入配置文件
    local conf_content="[Interface]
PrivateKey = ${private_key}
Address = ${vpn_ip}/24

[Peer]
PublicKey = ${server_pubkey}
Endpoint = ${server_endpoint}
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
"

    # tee 的退出码会被管道吞掉，用 PIPESTATUS 检查
    echo "$conf_content" | run_as_root tee "$WG_CONF_FILE" > /dev/null
    if [ "${PIPESTATUS[1]}" -ne 0 ]; then
        print_error "配置文件写入失败"
        return 1
    fi

    run_as_root chmod 600 "$WG_CONF_FILE"

    # 保存到临时文件供 systemd 服务使用
    echo "$vpn_ip" > "$TEMP_DIR/wg-vpn-ip"

    print_success "WireGuard 配置完成"
    print_info "配置文件: $WG_CONF_FILE"
    print_info "VPN IP: $vpn_ip"

    # 显示服务器端需要完成的操作
    local my_public_key=""
    if [ -f "${WG_CONF_DIR}/pi_public.key" ]; then
        my_public_key=$(cat "${WG_CONF_DIR}/pi_public.key")
    fi
    echo
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}  请将以下信息发送给服务器管理员${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo
    if [ -n "$my_public_key" ]; then
        echo -e "  本机公钥: ${GREEN}${my_public_key}${NC}"
    fi
    echo -e "  本机 VPN IP: ${GREEN}${vpn_ip}${NC}"
    echo
    echo -e "  ${RED}重要：服务器管理员需要完成以下操作才能建立连接：${NC}"
    echo -e "  1. 编辑服务器 WireGuard 配置: ${GREEN}sudo nano /etc/wireguard/wg0.conf${NC}"
    echo -e "  2. 在文件末尾添加 [Peer] 配置段："
    echo -e "     ${CYAN}[Peer]${NC}"
    if [ -n "$my_public_key" ]; then
        echo -e "     ${CYAN}PublicKey = ${my_public_key}${NC}"
    fi
    echo -e "     ${CYAN}AllowedIPs = ${vpn_ip}/32${NC}"
    echo -e "  3. ${RED}重启 WireGuard 服务: ${GREEN}sudo systemctl restart wg-quick@wg0${NC}"
    echo

    return 0
}

# -----------------------------------------------
# 配置 WireGuard（快速模式：指定参数直接生成）
# -----------------------------------------------
configure_wireguard_quick() {
    local vpn_ip="$1"
    local server_pubkey="$2"
    local server_endpoint="${3:-}"

    run_as_root mkdir -p "$WG_CONF_DIR"

    # 获取私钥
    local private_key=""
    if run_as_root test -f "${WG_CONF_DIR}/pi_private.key"; then
        private_key=$(run_as_root cat "${WG_CONF_DIR}/pi_private.key")
    else
        print_error "未找到私钥，请先生成密钥对"
        return 1
    fi

    if [ -z "$server_endpoint" ]; then
        print_error "服务器地址不能为空"
        return 1
    fi

    # 写入配置
    cat << EOF | run_as_root tee "$WG_CONF_FILE" > /dev/null
[Interface]
PrivateKey = ${private_key}
Address = ${vpn_ip}/24

[Peer]
PublicKey = ${server_pubkey}
Endpoint = ${server_endpoint}
AllowedIPs = 10.0.0.0/24
PersistentKeepalive = 25
EOF

    run_as_root chmod 600 "$WG_CONF_FILE"
    echo "$vpn_ip" > "$TEMP_DIR/wg-vpn-ip"

    print_success "WireGuard 配置完成 (快速模式)"
    print_info "VPN IP: $vpn_ip"
}

# -----------------------------------------------
# 启动 WireGuard 服务
# -----------------------------------------------
start_wireguard() {
    print_step "启动 WireGuard 服务"

    if ! run_as_root test -f "$WG_CONF_FILE"; then
        print_error "配置文件不存在: $WG_CONF_FILE"
        print_info "请先执行 WireGuard 配置"
        return 1
    fi

    # 验证配置语法
    if ! wg-quick strip wg0 &>/dev/null; then
        print_error "配置文件语法错误"
        return 1
    fi

    run_as_root systemctl enable wg-quick@wg0
    run_as_root systemctl restart wg-quick@wg0
    sleep 2

    if is_wireguard_running; then
        print_success "WireGuard 服务已启动"

        # 显示连接信息
        echo
        run_as_root wg show wg0 2>/dev/null || true
        echo

        return 0
    else
        print_error "WireGuard 服务启动失败"
        echo
        print_info "最近日志:"
        run_as_root journalctl -u wg-quick@wg0 -n 10 --no-pager 2>/dev/null || true
        echo
        print_info "常见原因:"
        print_info "  1. Endpoint 格式错误 (需 IP:端口)"
        print_info "  2. AllowedIPs 格式错误"
        print_info "  3. PrivateKey 无效"
        print_info "查看详细日志: sudo journalctl -u wg-quick@wg0 -n 30"
        return 1
    fi
}

# -----------------------------------------------
# 验证 WireGuard 连通性
# -----------------------------------------------
verify_wireguard() {
    print_step "验证 WireGuard VPN"

    if ! is_wireguard_installed; then
        print_warn "WireGuard 未安装，跳过验证"
        return 1
    fi

    if ! is_wireguard_running; then
        print_warn "WireGuard 服务未运行"
        return 1
    fi

    # 获取 VPN IP
    local vpn_ip
    vpn_ip=$(get_vpn_ip)
    print_info "本机 VPN IP: ${vpn_ip:-未分配}"

    # 检查连接状态
    echo
    print_info "WireGuard 连接状态:"
    run_as_root wg show wg0 2>/dev/null || print_warn "无法获取连接状态"

    # 测试服务器连通性
    echo
    print_info "测试 VPN 连通性..."
    if ping -c 3 -W 5 "$WG_DEFAULT_SERVER_IP" &>/dev/null; then
        print_success "VPN 连通: $WG_DEFAULT_SERVER_IP (可达)"
    else
        print_warn "VPN 连通: $WG_DEFAULT_SERVER_IP (不可达)"
        print_info "可能原因:"
        print_info "  1. 服务器端未添加本机公钥或未重启 WireGuard"
        print_info "     ${RED}请确认服务器管理员已执行: sudo systemctl restart wg-quick@wg0${NC}"
        print_info "  2. VPN IP 配置冲突"
        print_info "  3. 云服务器安全组未开放 UDP $WG_DEFAULT_PORT"
    fi

    # 测试 Nacos 连通性
    local nacos_ip="${NACOS_HOST:-$WG_DEFAULT_SERVER_IP}"
    if ping -c 1 -W 3 "$nacos_ip" &>/dev/null; then
        print_success "Nacos 服务器可达: $nacos_ip"
    else
        print_warn "Nacos 服务器不可达: $nacos_ip"
    fi

    return 0
}

# -----------------------------------------------
# WireGuard 完整安装向导
# -----------------------------------------------
setup_wireguard_wizard() {
    print_header "WireGuard VPN 配置向导"

    create_temp_dir

    # 步骤1: 检查/安装 WireGuard
    if ! is_wireguard_installed; then
        print_info "WireGuard 尚未安装"
        if ! confirm "是否安装 WireGuard?" "y"; then
            print_info "跳过 WireGuard 安装"
            return 1
        fi
        if ! install_wireguard; then
            return 1
        fi
    else
        print_info "WireGuard 已安装"
    fi

    # 步骤2: 生成密钥对
    if ! generate_wireguard_keys; then
        return 1
    fi

    # 步骤3: 配置客户端
    if ! configure_wireguard; then
        return 1
    fi

    # 步骤4: 启动服务
    if ! start_wireguard; then
        return 1
    fi

    # 步骤5: 验证
    verify_wireguard || true

    print_success "WireGuard 配置完成!"
    echo
    print_warn "请确保服务器端已添加本机公钥和 VPN IP"
}
