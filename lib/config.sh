#!/bin/bash
# =============================================================================
# 配置管理模块
# 处理服务器、桩、VPN的配置管理
# =============================================================================

# -----------------------------------------------
# 配置云快充平台连接参数
# -----------------------------------------------
configure_server() {
    print_step "配置云快充平台 (YKC)"

    local host port protocol software

    # 读取当前配置值
    if [ -f "$APP_DIR/config/application.yml" ]; then
        host=$(grep "host:" "$APP_DIR/config/application.yml" | head -1 | awk '{print $2}' | tr -d '"')
        port=$(grep -A1 "server:" "$APP_DIR/config/application.yml" | grep "port:" | grep -v "server.port" | head -1 | awk '{print $2}' | tr -d '"')
        protocol=$(grep "protocol-version:" "$APP_DIR/config/application.yml" | awk '{print $2}' | tr -d '"')
        software=$(grep "software-version:" "$APP_DIR/config/application.yml" | awk '{print $2}' | tr -d '"')
    fi

    # 设置默认值
    host=${host:-121.43.69.62}
    port=${port:-8767}
    protocol=${protocol:-V160}
    software=${software:-V1.6.0}

    echo
    echo -e "${GREEN}[说明]${NC} 云快充平台是充电桩连接的后台服务器"
    echo -e "${YELLOW}当前值在方括号中，直接回车使用默认值${NC}"
    echo

    host=$(safe_read "云快充平台地址" "$host")
    port=$(safe_read "云快充平台端口" "$port")
    protocol=$(safe_read "协议版本(V150/V160/V170)" "$protocol")
    software=$(safe_read "软件版本" "$software")

    # 保存到临时文件
    echo "$host:$port:$protocol:$software" > "$TEMP_DIR/hcp-server-config"
}

# -----------------------------------------------
# 配置桩和枪
# -----------------------------------------------
configure_piles() {
    print_step "配置桩"

    local piles=()
    local guns=()

    # 检查是否为交互环境
    if [[ ! -t 0 ]]; then
        print_warn "非交互环境，使用默认桩配置"
        piles=("32010601122277" "32010601122278")
        guns=("01 02" "01 02")
        printf '%s\n' "${piles[@]}" > "$TEMP_DIR/hcp-piles"
        printf '%s\n' "${guns[@]}" > "$TEMP_DIR/hcp-guns"
        return 0
    fi

    while true; do
        echo
        print_info "添加桩（14位编号，空回车结束）:"
        local pile_code
        read -p "桩编号: " pile_code

        # 空输入退出循环
        if [ -z "$pile_code" ]; then
            break
        fi

        # 验证桩编号格式
        if ! [[ "$pile_code" =~ ^[0-9]{14}$ ]]; then
            print_error "桩编号必须是14位数字"
            continue
        fi

        # 读取枪号
        local gun_input
        read -p "枪号(空格分隔，默认: 01 02): " gun_input
        gun_input=${gun_input:-"01 02"}

        piles+=("$pile_code")
        guns+=("$gun_input")

        print_success "已添加: $pile_code - 枪号: $gun_input"
    done

    # 如果没有配置桩，使用默认值
    if [ ${#piles[@]} -eq 0 ]; then
        print_warn "未配置桩，将使用默认值"
        piles=("32010601122277" "32010601122278")
        guns=("01 02" "01 02")
    fi

    # 保存到临时文件
    printf '%s\n' "${piles[@]}" > "$TEMP_DIR/hcp-piles"
    printf '%s\n' "${guns[@]}" > "$TEMP_DIR/hcp-guns"
}

# -----------------------------------------------
# 配置VPN参数
# -----------------------------------------------
configure_vpn() {
    print_step "配置VPN (可选)"

    local vpn_ip sim_id

    # 读取现有配置
    if [ -f "/etc/systemd/system/${SERVICE_NAME}" ]; then
        vpn_ip=$(grep "SPRING_CLOUD_NACOS_DISCOVERY_IP" "/etc/systemd/system/${SERVICE_NAME}" | cut -d'"' -f2)
        sim_id=$(grep "SIMULATOR_INSTANCE_ID" "/etc/systemd/system/${SERVICE_NAME}" | cut -d'"' -f2)
    fi

    # 设置默认值
    vpn_ip=${vpn_ip:-10.0.0.2}
    sim_id=${sim_id:-pi-01}

    echo
    vpn_ip=$(safe_read "VPN IP地址" "$vpn_ip")
    sim_id=$(safe_read "实例ID" "$sim_id")

    # 保存到临时文件
    echo "$vpn_ip:$sim_id" > "$TEMP_DIR/hcp-vpn-config"
}

# -----------------------------------------------
# 保存所有配置
# -----------------------------------------------
save_config() {
    print_step "保存配置"

    # 确保配置目录存在
    ensure_dir "$APP_DIR/config"

    # 读取服务器配置
    local server_config
    server_config=$(cat "$TEMP_DIR/hcp-server-config" 2>/dev/null || echo "121.43.69.62:8767:V160:V1.6.0")
    local ykc_host ykc_port protocol_version software_version
    IFS=':' read -r ykc_host ykc_port protocol_version software_version <<< "$server_config"

    # 生成YAML配置文件
    cat > "$APP_DIR/config/application.yml" << EOF
server:
  port: 18080

spring:
  application:
    name: hcp-simulator-lite
  datasource:
    driver-class-name: org.sqlite.JDBC
    url: jdbc:sqlite:./data/simulator.db
  sql:
    init:
      mode: always
      schema-locations: classpath:schema.sql
      continue-on-error: true

management:
  endpoints:
    web:
      exposure:
        include: health,info

# 云快充平台连接配置
ykc:
  server:
    host: ${ykc_host}
    port: ${ykc_port}
  protocol-version: ${protocol_version}
  software-version: "${software_version}"
  # 桩配置列表（每桩可配多把枪）
  piles:
EOF

    # 读取桩配置并添加到YAML
    if [ -f "$TEMP_DIR/hcp-piles" ] && [ -f "$TEMP_DIR/hcp-guns" ]; then
        local pile_arrays=()
        local gun_arrays=()

        # 读取桩和枪配置到数组
        while IFS= read -r line; do
            pile_arrays+=("$line")
        done < "$TEMP_DIR/hcp-piles"

        while IFS= read -r line; do
            gun_arrays+=("$line")
        done < "$TEMP_DIR/hcp-guns"

        # 生成桩配置
        for i in "${!pile_arrays[@]}"; do
            local pile="${pile_arrays[$i]}"
            local guns="${gun_arrays[$i]}"

            echo "    - pile-code: \"$pile\"" >> "$APP_DIR/config/application.yml"

            # 转换空格分隔的枪号为YAML数组格式
            local yaml_guns="["
            local first=true
            for gun in $guns; do
                if [ "$first" = true ]; then
                    first=false
                else
                    yaml_guns="${yaml_guns}, "
                fi
                yaml_guns="${yaml_guns}\"$gun\""
            done
            yaml_guns="${yaml_guns}]"
            echo "      guns: $yaml_guns" >> "$APP_DIR/config/application.yml"
        done
    fi

    # 设置文件权限
    chown "$(whoami):$(id -gn)" "$APP_DIR/config/application.yml"

    # 更新systemd服务中的VPN配置
    local vpn_config
    vpn_config=$(cat "$TEMP_DIR/hcp-vpn-config" 2>/dev/null || echo "10.0.0.2:pi-01")
    local vpn_ip sim_id
    IFS=':' read -r vpn_ip sim_id <<< "$vpn_config"

    # 更新systemd服务文件中的环境变量
    if [ -f "/etc/systemd/system/${SERVICE_NAME}" ]; then
        run_as_root sed -i "s|Environment=\"SPRING_CLOUD_NACOS_DISCOVERY_IP=.*\"|Environment=\"SPRING_CLOUD_NACOS_DISCOVERY_IP=$vpn_ip\"|" \
            "/etc/systemd/system/${SERVICE_NAME}" 2>/dev/null || true
        run_as_root sed -i "s|Environment=\"SIMULATOR_INSTANCE_ID=.*\"|Environment=\"SIMULATOR_INSTANCE_ID=$sim_id\"|" \
            "/etc/systemd/system/${SERVICE_NAME}" 2>/dev/null || true

        run_as_root systemctl daemon-reload
    fi

    print_success "配置已保存"

    # 清理临时文件
    rm -f "$TEMP_DIR"/hcp-server-config "$TEMP_DIR"/hcp-piles "$TEMP_DIR"/hcp-guns "$TEMP_DIR"/hcp-vpn-config
}

# -----------------------------------------------
# 运行配置向导
# -----------------------------------------------
run_config_wizard() {
    print_header "配置向导"

    # 检查是否已有配置
    if [ -f "$APP_DIR/config/application.yml" ]; then
        print_info "检测到现有配置，是否修改?"
        if ! confirm "修改配置?" "n"; then
            return 0
        fi
    fi

    # 确保临时目录存在
    create_temp_dir

    configure_server
    configure_piles
    configure_vpn
    save_config

    print_success "配置完成!"
}

# -----------------------------------------------
# 查看部署日志
# -----------------------------------------------
view_logs() {
    print_header "部署日志"

    if [ -f "$LOG_FILE" ]; then
        tail -100 "$LOG_FILE"
    else
        print_warn "未找到日志文件"
    fi
}
