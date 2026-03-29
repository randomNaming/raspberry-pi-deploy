#!/bin/bash
# =============================================================================
# 安装部署模块（主流程）
# 处理Java安装、目录创建、配置部署、服务部署、一键/手动部署流程
# 注意：镜像源管理在 mirror.sh，JAR下载在 download.sh
# =============================================================================

# -----------------------------------------------
# 安装 Java 运行环境
# 优先尝试更新软件源，失败则提示更换国内镜像
# -----------------------------------------------
install_java() {
    print_step "安装Java"

    if command_exists java; then
        local java_ver
        java_ver=$(java -version 2>&1 | head -1)
        print_info "Java已安装: $java_ver"
        if ! confirm "重新安装Java?" "n"; then
            return 0
        fi
    fi

    print_info "安装OpenJDK ${JAVA_MIN_VERSION}..."

    # 先尝试更新软件源，失败则提示换源
    if ! update_apt; then
        if confirm "是否更换为国内镜像源?" "y"; then
            change_mirror
            if ! update_apt; then
                print_error "更新软件源仍然失败，请手动检查"
                return 1
            fi
        else
            return 1
        fi
    fi

    if ! safe_exec "run_as_root apt install -y openjdk-${JAVA_MIN_VERSION}-jdk" "Java安装失败"; then
        return 1
    fi

    if command_exists java; then
        print_success "Java安装完成"
        return 0
    else
        print_error "Java安装失败"
        return 1
    fi
}

# -----------------------------------------------
# 创建应用目录结构（data、logs、config）
# -----------------------------------------------
create_dirs() {
    print_step "创建目录"

    mkdir -p "$APP_DIR"/{data,logs,config}
    print_success "目录创建完成: $APP_DIR"
    print_info "  - data/     (数据存储)"
    print_info "  - logs/     (日志文件)"
    print_info "  - config/   (配置文件)"

    return 0
}

# -----------------------------------------------
# 部署配置文件
# 优先查找 application-prod.yml，其次 application.yml
# 未找到时运行交互式配置向导
# -----------------------------------------------
deploy_config() {
    print_step "部署配置文件"

    local config_path=""

    # 搜索配置文件（优先查找 application-prod.yml）
    for dir in "$SCRIPT_DIR" "." "$HOME"; do
        if [ -f "$dir/application-prod.yml" ]; then
            config_path="$dir/application-prod.yml"
            break
        elif [ -f "$dir/application.yml" ]; then
            config_path="$dir/application.yml"
            break
        fi
    done

    # 如果找到的是 application.yml，检查是否已有 application-prod.yml
    if [ -f "$config_path" ] && [ "$(basename "$config_path")" = "application-prod.yml" ]; then
        ensure_dir "$APP_DIR/config"
        cp "$config_path" "$APP_DIR/config/application-prod.yml"
        chown "$(whoami):$(id -gn)" "$APP_DIR/config/application-prod.yml"
        print_info "已复制: application-prod.yml"

        # 同时复制 bootstrap.yml（如果有）
        for dir in "$SCRIPT_DIR" "." "$HOME"; do
            if [ -f "$dir/bootstrap.yml" ]; then
                cp "$dir/bootstrap.yml" "$APP_DIR/config/bootstrap.yml"
                chown "$(whoami):$(id -gn)" "$APP_DIR/config/bootstrap.yml"
                print_info "已复制: bootstrap.yml"
                break
            fi
        done

        print_success "配置部署完成"
        return 0
    elif [ -f "$config_path" ]; then
        # 旧版 application.yml 格式
        ensure_dir "$APP_DIR/config"
        cp "$config_path" "$APP_DIR/config/application.yml"
        chown "$(whoami):$(id -gn)" "$APP_DIR/config/application.yml"
        print_info "已复制: application.yml (旧版格式)"
        print_success "配置部署完成"
        return 0
    fi

    # 未找到配置文件，运行交互式向导
    print_warn "未找到配置文件，将进入配置向导"
    create_default_config
    return 0
}

# -----------------------------------------------
# 创建默认配置文件（交互式）
# 引导用户输入平台地址、桩号等信息，生成 YAML 配置
# -----------------------------------------------
create_default_config() {
    print_header "创建配置文件"

    # 交互式输入桩信息（非交互环境跳过）
    local pile_codes=()
    local pile_guns=()
    local instance_id="pi-01"
    local ykc_host="121.43.69.62"
    local ykc_port="8767"
    local protocol_version="V160"
    local software_version="V1.6.0"

    if [[ -t 0 ]]; then
        echo
        echo -e "${CYAN}--- 云快充平台连接配置 ---${NC}"
        echo -e "${GREEN}[说明]${NC} 云快充平台是充电桩连接的后台服务器"
        echo

        # 服务器配置
        ykc_host=$(safe_read "云快充平台地址" "$ykc_host")
        ykc_port=$(safe_read "云快充平台端口" "$ykc_port")
        protocol_version=$(safe_read "协议版本" "$protocol_version")
        software_version=$(safe_read "软件版本" "$software_version")

        # 实例ID
        echo
        instance_id=$(safe_read "实例ID" "$instance_id")

        # 桩配置
        echo
        echo -e "${CYAN}--- 桩号配置 ---${NC}"
        echo -e "${GREEN}[说明]${NC} 输入起始桩号和连续数量，自动生成连续桩号"
        echo -e "${GREEN}[说明]${NC} 例：起始桩号 32010601135756，数量 3，生成 5756/5757/5758"
        echo

        while true; do
            local start_code
            start_code=$(safe_read "起始桩号(14位数字，留空结束)" "")

            # 空输入退出
            if [ -z "$start_code" ]; then
                # 如果已配置桩，退出循环
                if [ ${#pile_codes[@]} -gt 0 ]; then
                    break
                fi
                # 未配置桩时必须输入
                print_warn "至少需要配置一个桩号"
                continue
            fi

            # 验证桩号格式（14位纯数字）
            if ! [[ "$start_code" =~ ^[0-9]{14}$ ]]; then
                print_error "桩号必须是14位纯数字"
                continue
            fi

            # 输入数量
            local pile_count
            pile_count=$(safe_read "连续桩数量" "1")
            if ! [[ "$pile_count" =~ ^[0-9]+$ ]] || [ "$pile_count" -lt 1 ]; then
                print_error "数量必须是正整数"
                continue
            fi

            # 输入枪号
            local gun_input
            gun_input=$(safe_read "枪号(空格分隔)" "01 02")
            gun_input=${gun_input:-"01 02"}

            # 生成连续桩号
            local code_len=${#start_code}
            local suffix_digits=2
            local prefix="${start_code:0:$((code_len - suffix_digits))}"
            local last_part="${start_code:$((code_len - suffix_digits))}"
            local base=$((10#$last_part))

            for ((i=0; i<pile_count; i++)); do
                local seq=$((base + i))
                local code
                if [ "$seq" -lt 100 ]; then
                    # 正常情况：补齐2位，总长度不变
                    code="${prefix}$(printf '%02d' $seq)"
                else
                    # 溢出：缩减前缀1位，用3位数字，保持总长度不变
                    local smaller_prefix="${prefix:0:$((code_len - suffix_digits - 1))}"
                    code="${smaller_prefix}$(printf '%03d' $seq)"
                fi
                pile_codes+=("$code")
                pile_guns+=("$gun_input")
                echo -e "  ${GREEN}+${NC} $code  枪号: $gun_input"
            done
            echo
        done
    else
        # 非交互环境使用默认值
        pile_codes=("32010601122277" "32010601122278")
        pile_guns=("01 02" "01 02")
        print_warn "非交互环境，使用默认桩配置"
    fi

    # ---- 生成 application-prod.yml ----
    local prod_file="$APP_DIR/config/application-prod.yml"
    ensure_dir "$APP_DIR/config"

    cat > "$prod_file" << EOF
server:
  port: 18080

# 生产环境配置

# 模拟器实例标识（每台树莓派设置不同的值，如 pi-01、pi-02）
simulator-lite:
  instance-id: \${SIMULATOR_INSTANCE_ID:${instance_id}}

# 云快充平台模拟桩配置
ykc:
  # 生产环境：应用启动时自动启动所有配置的充电桩
  auto-start: true
  server:
    host: ${ykc_host}
    port: ${ykc_port}
  protocol-version: ${protocol_version}
  software-version: "${software_version}"
  # 桩配置列表（每桩可配多把枪）
  piles:
EOF

    # 写入桩配置
    for i in "${!pile_codes[@]}"; do
        local pile="${pile_codes[$i]}"
        local guns="${pile_guns[$i]}"

        cat >> "$prod_file" << EOF
    - pile-code: "$pile"
EOF

        # 将空格分隔的枪号转为YAML数组格式
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
        echo "      guns: $yaml_guns" >> "$prod_file"
    done

    print_success "已创建: $prod_file"

    # ---- 生成 bootstrap.yml ----
    local bootstrap_file="$APP_DIR/config/bootstrap.yml"

    cat > "$bootstrap_file" << 'EOF'
spring:
  application:
    name: hcp-simulator-lite

  # 建议通过启动参数或环境变量覆盖：
  #   -Dspring.profiles.active=dev 或 prod
  # 这里给一个默认值，方便本地开发
  profiles:
    active: prod

  cloud:
    nacos:
      # Nacos 服务注册发现（网关通过服务名发现 simulator-lite 实例）
      discovery:
        server-addr: ${NACOS_HOST:127.0.0.1}:${NACOS_PORT:8848}
        namespace: hcp
      # Nacos 配置中心（加载 application-dev.yml / application-prod.yml 等改为从 Nacos 读取）
      config:
        server-addr: ${spring.cloud.nacos.discovery.server-addr}
        file-extension: yml
        namespace: hcp

        # 公共配置（所有环境共享），对应 Nacos 中 dataId = hcp-simulator-lite.yml
        shared-configs:
          - application-${spring.profiles.active}.${spring.cloud.nacos.config.file-extension}
          - data-id: ${spring.application.name}.${spring.cloud.nacos.config.file-extension}
            refresh: true
EOF

    print_success "已创建: $bootstrap_file"

    # 同时创建兼容旧版 application.yml（指向 prod profile）
    local app_file="$APP_DIR/config/application.yml"
    cat > "$app_file" << 'EOF'
spring:
  profiles:
    active: prod
EOF

    print_info "配置文件创建完成:"
    print_info "  - application-prod.yml  (主配置)"
    print_info "  - bootstrap.yml         (Nacos配置)"
    print_info "  - application.yml       (Profile入口)"
    echo
    print_warn "请确认桩号配置是否正确，如需修改可直接编辑配置文件"
}

# -----------------------------------------------
# 部署 systemd 服务单元文件
# 生成服务文件并注册到系统
# -----------------------------------------------
deploy_service() {
    print_step "部署Systemd服务"

    # 创建服务文件内容
    local service_content="[Unit]
Description=HCP Simulator Lite - 云快充模拟桩服务
After=network.target wg-quick@wg0.service
Requires=wg-quick@wg0.service

[Service]
Type=simple
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=${APP_DIR}
Environment=\"NACOS_HOST=10.0.0.1\"
Environment=\"NACOS_PORT=8848\"
Environment=\"SPRING_CLOUD_NACOS_DISCOVERY_IP=10.0.0.2\"
Environment=\"SPRING_CLOUD_NACOS_DISCOVERY_PORT=18080\"
Environment=\"SIMULATOR_INSTANCE_ID=pi-01\"
ExecStart=/usr/bin/java -Xms256m -Xmx1024m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Dfile.encoding=UTF-8 -Dspring.profiles.active=prod -jar ${APP_DIR}/${JAR_FILE}
ExecStop=/bin/kill -15 \$MAINPID
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
"

    echo "$service_content" | run_as_root tee "/etc/systemd/system/${SERVICE_NAME}" > /dev/null

    run_as_root systemctl daemon-reload
    run_as_root systemctl enable "${SERVICE_NAME}"

    print_success "服务部署完成"
    return 0
}

# -----------------------------------------------
# 启动应用服务并验证状态
# -----------------------------------------------
start_service() {
    print_step "启动服务"

    run_as_root systemctl daemon-reload
    run_as_root systemctl enable "${SERVICE_NAME}"
    run_as_root systemctl restart "${SERVICE_NAME}"
    sleep 3

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_success "服务启动成功"
        return 0
    else
        print_error "服务启动失败"
        print_info "查看日志: journalctl -u ${SERVICE_NAME} -n 50"
        return 1
    fi
}

# -----------------------------------------------
# 验证部署结果（检查服务、JAR、配置、健康状态）
# -----------------------------------------------
verify_deployment() {
    print_step "验证部署"

    echo
    print_info "1. 检查服务状态..."
    run_as_root systemctl status "${SERVICE_NAME}" --no-pager -l 2>/dev/null || true

    echo
    print_info "2. 检查JAR文件..."
    if [ -f "$APP_DIR/${JAR_FILE}" ]; then
        print_success "JAR文件存在"
    else
        print_error "JAR文件缺失"
    fi

    echo
    print_info "3. 检查配置文件..."
    local config_found=false
    for f in bootstrap.yml application-prod.yml application.yml; do
        if [ -f "$APP_DIR/config/$f" ]; then
            print_success "配置文件存在: $f"
            config_found=true
        fi
    done
    if [ "$config_found" = false ]; then
        print_error "配置文件缺失"
    fi

    echo
    print_info "4. 检查应用健康状态..."
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:18080/actuator/health" 2>/dev/null | grep -q "200"; then
        print_success "应用响应正常"
    else
        print_warn "应用可能尚未响应（请等待启动）"
    fi

    return 0
}

# -----------------------------------------------
# 一键自动部署（完整自动化流程）
# 包含环境检测、快照、VPN、Java、目录、JAR、配置、服务
# -----------------------------------------------
auto_deploy() {
    local total_steps=9
    local current_step=0

    print_header "一键自动部署"
    print_info "开始自动部署..."
    echo

    # 初始化状态
    init_state
    update_state "PHASE" "PRECHECK"

    # 步骤1: 环境检测
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 环境检测"

    if ! run_all_checks; then
        if ! confirm "环境检测有问题，继续部署?" "n"; then
            print_info "部署已取消"
            return 1
        fi
    fi
    mark_complete "precheck"

    # 步骤2: 创建快照
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 创建备份快照"
    local snapshot_id
    snapshot_id=$(create_snapshot)
    echo

    # 步骤3: WireGuard VPN（必须配置）
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: WireGuard VPN"

    if is_wireguard_installed 2>/dev/null && is_wireguard_running 2>/dev/null; then
        print_info "WireGuard 已安装并运行"

        # 验证VPN连通性
        if ping -c 1 -W 3 10.0.0.1 &>/dev/null; then
            print_success "VPN 连通性正常"
        else
            print_warn "VPN 无法连接服务器 (10.0.0.1)"
            print_info "请检查服务器端是否已添加本机公钥并重启 WireGuard"
            print_info "  服务器执行: sudo systemctl restart wg-quick@wg0"
            if confirm "重新配置 WireGuard?" "y"; then
                if ! setup_wireguard_wizard; then
                    print_error "WireGuard 配置失败，无法继续部署"
                    return 1
                fi
            fi
        fi
    else
        print_info "WireGuard 是必需的，用于连接内网服务器"
        if ! setup_wireguard_wizard; then
            print_error "WireGuard 配置失败，无法继续部署"
            return 1
        fi

        # 验证VPN连通性
        print_info "验证VPN连通性..."
        if ! ping -c 3 -W 5 10.0.0.1 &>/dev/null; then
            print_error "VPN 无法连接服务器 (10.0.0.1)"
            print_info "请检查:"
            print_info "  1. 服务器端是否已添加本机公钥"
            print_info "  2. ${RED}服务器管理员是否已重启 WireGuard: sudo systemctl restart wg-quick@wg0${NC}"
            print_info "  3. 服务器安全组是否开放 UDP 51820"
            print_info "  4. WireGuard配置是否正确"
            if ! confirm "跳过VPN检查继续部署?" "n"; then
                return 1
            fi
        else
            print_success "VPN 连通性正常"
        fi
    fi
    mark_complete "wireguard"

    # 步骤4: 安装Java
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: Java安装"

    if ! check_java &>/dev/null; then
        print_info "正在安装Java..."
        if ! update_apt; then
            if confirm "是否更换为国内镜像源?" "y"; then
                change_mirror
                update_apt || true
            fi
        fi
        run_as_root apt install -y "openjdk-${JAVA_MIN_VERSION}-jdk"

        if ! check_java &>/dev/null; then
            mark_failed "java_install" "Java安装失败"
            rollback_prompt "$snapshot_id"
            return 1
        fi
    fi
    mark_complete "java_install"

    # 步骤5: 创建目录
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 创建目录结构"
    create_dirs
    mark_complete "create_dirs"

    # 步骤6: 部署JAR
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 部署应用"

    if ! deploy_jar; then
        mark_failed "deploy_jar" "JAR部署失败"
        rollback_prompt "$snapshot_id"
        return 1
    fi
    mark_complete "deploy_jar"

    # 步骤7: 部署配置
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 部署配置"
    deploy_config
    mark_complete "deploy_config"

    # 步骤8: 部署服务
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 部署系统服务"
    deploy_service
    mark_complete "deploy_service"

    # 步骤9: 启动服务
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 启动服务"

    # 检查配置是否存在
    if [ ! -f "$APP_DIR/config/application-prod.yml" ] && [ ! -f "$APP_DIR/config/application.yml" ]; then
        print_warn "未找到配置文件"
        if confirm "运行配置向导?" "y"; then
            run_config_wizard
        fi
    fi

    if ! start_service; then
        mark_failed "service_start" "服务启动失败"
        print_info "请检查日志并手动启动服务"
        print_info "sudo systemctl start ${APP_NAME}"
        return 1
    fi
    mark_complete "service_start"

    # 显示部署摘要
    show_deployment_summary

    update_state "PHASE" "COMPLETE"
    mark_complete "auto_deploy"

    print_success "一键部署完成!"
}

# -----------------------------------------------
# 手动部署模式（逐步选择执行）
# 用户可自由选择执行顺序和步骤
# -----------------------------------------------
manual_deploy() {
    local completed=()
    local failed=()

    print_header "手动部署模式"
    print_info "逐步部署，完全控制"
    echo

    while true; do
        echo "========================================"
        echo "  手动部署 - 选择步骤"
        echo "========================================"
        echo

        local options=(
            "安装Java"
            "创建目录"
            "部署JAR文件"
            "部署配置文件"
            "部署系统服务"
            "配置桩/服务器 (可选)"
            "WireGuard VPN (可选)"
            "启动服务"
            "验证部署"
            "返回主菜单"
        )

        for i in "${!options[@]}"; do
            local num=$((i+1))
            local status=""
            if [[ " ${completed[*]} " =~ " $i " ]]; then
                status=" ${GREEN}[完成]${NC}"
            elif [[ " ${failed[*]} " =~ " $i " ]]; then
                status=" ${RED}[失败]${NC}"
            fi
            echo -e "  [$num] ${options[$i]}${status}"
        done

        echo
        echo -e "  ${YELLOW}[提示]${NC} 步骤4已包含桩/服务器配置，步骤6可跳过"
        echo

        local choice
        safe_read_char "选择步骤 [1-${#options[@]}]" choice
        echo

        local result=0

        case $choice in
            1)  install_java; result=$? ;;
            2)  create_dirs; result=$? ;;
            3)  deploy_jar; result=$? ;;
            4)  deploy_config; result=$? ;;
            5)  deploy_service; result=$? ;;
            6)  run_config_wizard; result=$? ;;
            7)  setup_wireguard_wizard; result=$? ;;
            8)  start_service; result=$? ;;
            9)  verify_deployment; result=$? ;;
            10) return 0 ;;
            *)
                if [ -n "$choice" ]; then
                    print_error "无效选择"
                fi
                ;;
        esac

        # 记录结果
        if [ $result -eq 0 ] && [ -n "$choice" ]; then
            completed+=("$((choice-1))")
        elif [ -n "$choice" ]; then
            failed+=("$((choice-1))")
        fi

        # 检查是否全部完成（7个必选步骤，步骤6可选）
        if [ ${#completed[@]} -ge 7 ]; then
            echo
            print_success "所有部署步骤完成!"
            break
        fi
    done
}

# -----------------------------------------------
# 显示部署摘要信息
# 展示应用名称、目录、服务状态和常用命令
# -----------------------------------------------
show_deployment_summary() {
    echo
    print_header "部署摘要"
    echo

    echo -e "  应用名称: ${GREEN}${APP_NAME}${NC}"
    echo -e "  安装目录: ${GREEN}${APP_DIR}${NC}"
    echo -e "  配置文件: ${GREEN}${APP_DIR}/config/application.yml${NC}"
    echo

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        echo -e "  服务状态: ${GREEN}运行中${NC}"
    else
        echo -e "  服务状态: ${RED}已停止${NC}"
    fi

    echo
    print_info "常用命令:"
    echo "  查看状态: sudo systemctl status ${APP_NAME}"
    echo "  查看日志: sudo journalctl -u ${APP_NAME} -f"
    echo "  停止服务: sudo systemctl stop ${APP_NAME}"
    echo "  重启服务: sudo systemctl restart ${APP_NAME}"
}
