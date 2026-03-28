#!/bin/bash
# =============================================================================
# 安装部署模块
# 处理Java安装、目录创建、JAR部署、配置部署、服务部署
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

# -----------------------------------------------
# 安装Java
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
# 创建应用目录结构
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
# 获取最新发行版版本号
# -----------------------------------------------
get_latest_release() {
    local api_url="https://gitee.com/api/v5/repos/garrettxia/raspberry-pi-deploy/releases/latest"
    local version

    version=$(curl -sL --connect-timeout 10 --max-time 15 "$api_url" 2>/dev/null | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)

    if [ -n "$version" ]; then
        echo "$version"
        return 0
    fi

    # 备用方式：从GitHub获取
    api_url="https://api.github.com/repos/randomNaming/raspberry-pi-deploy/releases/latest"
    version=$(curl -sL --connect-timeout 10 --max-time 15 "$api_url" 2>/dev/null | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)

    echo "$version"
}

# -----------------------------------------------
# 从发行版下载JAR
# -----------------------------------------------
DOWNLOADED_JAR_PATH=""

download_jar_from_release() {
    local version="$1"
    local jar_url=""
    local temp_jar="/tmp/${JAR_FILE}.download"
    DOWNLOADED_JAR_PATH=""

    # 清理旧文件
    rm -f "$temp_jar"

    print_info "正在下载 ${JAR_FILE} (版本: ${version})..."

    # Gitee 下载链接
    jar_url="https://gitee.com/garrettxia/raspberry-pi-deploy/releases/download/${version}/${JAR_FILE}"
    print_info "下载地址: ${jar_url}"

    # 下载文件（-L 跟随重定向）
    local http_code
    http_code=$(curl -sL --connect-timeout 15 --max-time 300 -w "%{http_code}" -o "$temp_jar" "$jar_url" 2>/dev/null)
    print_info "HTTP状态码: ${http_code}"

    if [ -f "$temp_jar" ] && [ -s "$temp_jar" ]; then
        local file_size
        file_size=$(du -h "$temp_jar" | cut -f1)
        print_info "文件大小: ${file_size}"

        # 检查是否为HTML错误页面
        if head -c 100 "$temp_jar" 2>/dev/null | grep -qi "<!DOCTYPE\|<html\|<head"; then
            print_warn "下载的是HTML页面，非JAR文件"
            rm -f "$temp_jar"
        else
            print_success "下载成功: ${temp_jar}"
            DOWNLOADED_JAR_PATH="$temp_jar"
            return 0
        fi
    else
        print_warn "文件为空或不存在"
    fi

    # 备用：从GitHub下载
    print_info "尝试从GitHub下载..."
    jar_url="https://github.com/randomNaming/raspberry-pi-deploy/releases/download/${version}/${JAR_FILE}"
    print_info "下载地址: ${jar_url}"

    rm -f "$temp_jar"
    http_code=$(curl -sL --connect-timeout 15 --max-time 300 -w "%{http_code}" -o "$temp_jar" "$jar_url" 2>/dev/null)
    print_info "HTTP状态码: ${http_code}"

    if [ -f "$temp_jar" ] && [ -s "$temp_jar" ]; then
        local file_size
        file_size=$(du -h "$temp_jar" | cut -f1)
        print_info "文件大小: ${file_size}"

        if head -c 100 "$temp_jar" 2>/dev/null | grep -qi "<!DOCTYPE\|<html\|<head"; then
            print_warn "下载的是HTML页面，非JAR文件"
            rm -f "$temp_jar"
        else
            print_success "下载成功: ${temp_jar}"
            DOWNLOADED_JAR_PATH="$temp_jar"
            return 0
        fi
    else
        print_warn "文件为空或不存在"
    fi

    rm -f "$temp_jar"
    return 1
}

# -----------------------------------------------
# 部署JAR文件
# -----------------------------------------------
deploy_jar() {
    print_step "部署JAR文件"

    local jar_path=""

    # 搜索JAR文件位置
    for dir in "$SCRIPT_DIR" "$HOME" "." "/tmp"; do
        if [ -f "$dir/${JAR_FILE}" ]; then
            jar_path="$dir/${JAR_FILE}"
            break
        fi
    done

    # 如果未找到本地文件，尝试从发行版下载
    if [ -z "$jar_path" ]; then
        print_info "本地未找到 ${JAR_FILE}，尝试从发行版下载..."

        # 获取最新版本号
        local latest_version
        latest_version=$(get_latest_release)

        if [ -z "$latest_version" ]; then
            print_error "无法获取最新版本号"
        else
            print_info "最新发行版: ${latest_version}"

            if confirm "是否下载 ${JAR_FILE}?" "y"; then
                if download_jar_from_release "$latest_version"; then
                    jar_path="$DOWNLOADED_JAR_PATH"
                    print_success "下载完成"
                else
                    print_error "下载失败"
                fi
            fi
        fi
    fi

    # 如果仍未找到，提示用户输入路径
    if [ -z "$jar_path" ]; then
        print_error "未找到JAR文件: ${JAR_FILE}"
        print_info "请将JAR文件放置到以下位置之一:"
        print_info "  - 脚本目录: $SCRIPT_DIR"
        print_info "  - home目录: $HOME"
        print_info "  - 当前目录: $(pwd)"

        jar_path=$(safe_read "输入JAR文件路径" "")
        if [ -z "$jar_path" ]; then
            print_error "未提供JAR文件路径"
            return 1
        fi
    fi

    # 验证文件存在
    if [ ! -f "$jar_path" ]; then
        print_error "文件不存在: $jar_path"
        return 1
    fi

    print_info "源文件: $jar_path"
    print_info "目标: $APP_DIR/${JAR_FILE}"

    cp "$jar_path" "$APP_DIR/${JAR_FILE}"
    chmod +x "$APP_DIR/${JAR_FILE}"
    chown -R "$(whoami):$(id -gn)" "$APP_DIR/${JAR_FILE}"

    print_success "JAR部署完成"
    return 0
}

# -----------------------------------------------
# 部署配置文件
# -----------------------------------------------
deploy_config() {
    print_step "部署配置文件"

    local config_path=""

    # 搜索配置文件
    for dir in "$SCRIPT_DIR" "." "$HOME"; do
        if [ -f "$dir/application.yml" ]; then
            config_path="$dir/application.yml"
            break
        fi
    done

    if [ -z "$config_path" ]; then
        print_warn "未找到配置文件，将创建默认配置"
        create_default_config
        return 0
    fi

    print_info "源文件: $config_path"
    print_info "目标: $APP_DIR/config/application.yml"

    cp "$config_path" "$APP_DIR/config/application.yml"
    chown "$(whoami):$(id -gn)" "$APP_DIR/config/application.yml"

    print_success "配置部署完成"
    return 0
}

# -----------------------------------------------
# 创建默认配置文件
# -----------------------------------------------
create_default_config() {
    cat > "$APP_DIR/config/application.yml" << 'EOF'
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
    host: 121.43.69.62
    port: 8767
  protocol-version: V160
  software-version: "V1.6.0"
  # 桩配置列表（每桩可配多把枪）
  piles:
    - pile-code: "32010601122277"
      guns: ["01", "02"]
    - pile-code: "32010601122278"
      guns: ["01", "02"]
EOF

    chown "$(whoami):$(id -gn)" "$APP_DIR/config/application.yml"
    print_info "默认配置文件已创建: $APP_DIR/config/application.yml"
    print_warn "请根据实际情况修改配置文件中的桩信息"
}

# -----------------------------------------------
# 部署systemd服务
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
ExecStart=/usr/bin/java -Xms256m -Xmx1024m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -Dfile.encoding=UTF-8 -Dspring.profiles.active=prod -jar ${APP_DIR}/${JAR_FILE} --spring.config.location=file:${APP_DIR}/config/application.yml
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
# 启动服务
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
# 验证部署结果
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
    if [ -f "$APP_DIR/config/application.yml" ]; then
        print_success "配置文件存在"
    else
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
# 一键自动部署
# -----------------------------------------------
auto_deploy() {
    local total_steps=8
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

    # 步骤3: 安装Java
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

    # 步骤4: 创建目录
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 创建目录结构"
    create_dirs
    mark_complete "create_dirs"

    # 步骤5: 部署JAR
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 部署应用"

    if ! deploy_jar; then
        mark_failed "deploy_jar" "JAR部署失败"
        rollback_prompt "$snapshot_id"
        return 1
    fi
    mark_complete "deploy_jar"

    # 步骤6: 部署配置
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 部署配置"
    deploy_config
    mark_complete "deploy_config"

    # 步骤7: 部署服务
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 部署系统服务"
    deploy_service
    mark_complete "deploy_service"

    # 步骤8: 配置并启动
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: 配置并启动服务"

    echo
    if confirm "运行配置向导?" "y"; then
        run_config_wizard
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
# 手动部署模式
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
            "配置桩/服务器"
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
            7)  start_service; result=$? ;;
            8)  verify_deployment; result=$? ;;
            9)  return 0 ;;
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

        # 检查是否全部完成（8个步骤，索引0-7）
        if [ ${#completed[@]} -eq 8 ]; then
            echo
            print_success "所有部署步骤完成!"
            break
        fi
    done
}

# -----------------------------------------------
# 显示部署摘要
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
