#!/bin/bash
# =============================================================================
# 环境检测模块
# 检测操作系统、架构、Java、网络、磁盘等环境条件
# =============================================================================

# -----------------------------------------------
# 检查是否为root用户
# -----------------------------------------------
check_root() {
    if is_root; then
        print_warn "不建议使用root用户运行此脚本，请使用普通用户"
        return 1
    fi
    return 0
}

# -----------------------------------------------
# 检查操作系统和架构
# -----------------------------------------------
check_system() {
    print_step "检测系统"

    local errors=0

    # 操作系统检查
    print_info "检查操作系统..."
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        if [[ "$ID" == "raspbian" || "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
            print_success "操作系统: $PRETTY_NAME"
        else
            print_warn "操作系统: $PRETTY_NAME (非官方支持系统)"
        fi
    else
        print_error "无法检测操作系统"
        ((errors++))
    fi

    # 架构检查
    print_info "检查架构..."
    local arch
    arch=$(uname -m)
    case "$arch" in
        aarch64|armv7l|x86_64)
            print_success "架构: $arch"
            ;;
        *)
            print_error "不支持的架构: $arch"
            ((errors++))
            ;;
    esac

    # 内存检查
    print_info "检查内存..."
    local mem_total
    mem_total=$(free -m | awk '/^Mem:/{print $2}')
    if [ "$mem_total" -ge 2048 ]; then
        print_success "内存: ${mem_total}MB (充足)"
    elif [ "$mem_total" -ge 1024 ]; then
        print_warn "内存: ${mem_total}MB (偏低，建议4GB+)"
    else
        print_error "内存: ${mem_total}MB (不足)"
        ((errors++))
    fi

    return $errors
}

# -----------------------------------------------
# 检查Java环境
# -----------------------------------------------
check_java() {
    print_step "检测Java"

    local java_cmd=""
    local java_ver=""
    local major=""

    # 方式1: 通过PATH查找java命令
    if command_exists java; then
        java_cmd="java"
    fi

    # 方式2: 检查常见Java安装路径
    if [ -z "$java_cmd" ]; then
        local java_paths=(
            "/usr/bin/java"
            "/usr/local/bin/java"
            "/opt/java/*/bin/java"
            "/usr/lib/jvm/*/bin/java"
            "/usr/java/*/bin/java"
        )
        for pattern in "${java_paths[@]}"; do
            for path in $pattern; do
                if [ -x "$path" ]; then
                    java_cmd="$path"
                    break 2
                fi
            done
        done
    fi

    # 方式3: 通过update-alternatives查找
    if [ -z "$java_cmd" ]; then
        local alt_java
        alt_java=$(update-alternatives --list java 2>/dev/null | head -1 || true)
        if [ -n "$alt_java" ] && [ -x "$alt_java" ]; then
            java_cmd="$alt_java"
        fi
    fi

    # 未找到Java
    if [ -z "$java_cmd" ]; then
        print_error "Java未安装"
        print_info "安装命令: sudo apt install -y openjdk-8-jdk"
        return 1
    fi

    # 获取Java版本（兼容多种输出格式）
    # 格式1: openjdk version "17.0.12" 2024-07-16
    # 格式2: java version "1.8.0_392"
    # 格式3: java 21.0.1 2023-10-17 LTS (某些新版本格式)
    local version_line
    version_line=$("$java_cmd" -version 2>&1 | head -1)

    # 提取版本号（引号内的内容或直接的版本号）
    if [[ "$version_line" =~ \"([^\"]+)\" ]]; then
        java_ver="${BASH_REMATCH[1]}"
    elif [[ "$version_line" =~ ([0-9]+\.[0-9]+\.[0-9]+[_0-9]*) ]]; then
        java_ver="${BASH_REMATCH[1]}"
    else
        java_ver="$version_line"
    fi

    print_info "检测到版本字符串: $java_ver"

    # 提取主版本号
    major=$(echo "$java_ver" | cut -d'.' -f1 | sed 's/[^0-9]//g')

    # 处理Java 1.x.x格式（如1.8.0_392 -> 主版本为8）
    if [ "$major" = "1" ]; then
        local minor
        minor=$(echo "$java_ver" | cut -d'.' -f2)
        if [ -n "$minor" ]; then
            major="$minor"
        fi
    fi

    # 验证主版本号是否为有效数字
    if ! [[ "$major" =~ ^[0-9]+$ ]]; then
        print_warn "无法解析Java主版本号: $major"
        print_info "原始版本: $java_ver"
        print_info "Java路径: $java_cmd"
        return 0
    fi

    # 检查版本是否满足要求
    if [ "$major" -ge "$JAVA_MIN_VERSION" ]; then
        print_success "Java版本: $java_ver (主版本: $major)"
    else
        print_warn "Java版本过低: $java_ver (主版本: $major，要求: ${JAVA_MIN_VERSION}+)"
        print_info "当前Java可用，但建议安装: sudo apt install -y openjdk-8-jdk"
    fi

    print_info "Java路径: $java_cmd"

    if [ -n "${JAVA_HOME:-}" ]; then
        print_info "JAVA_HOME: $JAVA_HOME"
    else
        print_warn "JAVA_HOME未设置"
    fi

    return 0
}

# -----------------------------------------------
# 检查网络连接
# -----------------------------------------------
check_network() {
    print_step "检测网络"

    local errors=0

    # 网络连接测试
    print_info "检查网络连接..."
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        print_success "网络: 已连接"
    elif ping -c 1 -W 3 114.114.114.114 &>/dev/null; then
        print_success "网络: 已连接 (备用)"
    else
        print_error "网络: 无法访问"
        ((errors++))
    fi

    # DNS解析测试（使用国内可达的域名）
    print_info "检查DNS..."
    local dns_ok=false
    local test_domains=("baidu.com" "qq.com" "taobao.com" "aliyun.com")

    for domain in "${test_domains[@]}"; do
        if host "$domain" &>/dev/null || nslookup "$domain" &>/dev/null; then
            print_success "DNS: 正常 (已解析 $domain)"
            dns_ok=true
            break
        fi
    done

    # 尝试通过getent检测DNS
    if [ "$dns_ok" = false ]; then
        if getent hosts baidu.com &>/dev/null; then
            print_success "DNS: 正常 (通过getent)"
            dns_ok=true
        fi
    fi

    if [ "$dns_ok" = false ]; then
        print_error "DNS: 异常"
        ((errors++))
    fi

    return $errors
}

# -----------------------------------------------
# 检查WireGuard VPN状态
# -----------------------------------------------
check_vpn() {
    print_step "检测WireGuard VPN"

    # 检查VPN服务是否存在
    if ! systemctl list-unit-files 2>/dev/null | grep -q "$VPN_SERVICE"; then
        print_warn "WireGuard服务未配置（可选）"
        return 0
    fi

    # 检查VPN是否激活
    if systemctl is-active --quiet "$VPN_SERVICE" 2>/dev/null; then
        print_success "WireGuard VPN: 已激活"

        # 获取VPN IP地址
        local vpn_ip
        vpn_ip=$(ip addr show wg0 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
        if [ -n "$vpn_ip" ]; then
            print_info "VPN IP: $vpn_ip"
        fi
    else
        print_warn "WireGuard VPN: 未激活（可选，不影响部署）"
    fi

    return 0
}

# -----------------------------------------------
# 检查磁盘空间
# -----------------------------------------------
check_disk() {
    print_step "检测磁盘空间"

    local home_free
    home_free=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | tr -d 'G')

    print_info "$HOME 可用空间: ${home_free}GB"

    if [ "$home_free" -ge 5 ]; then
        print_success "磁盘空间: 充足"
    elif [ "$home_free" -ge 2 ]; then
        print_warn "磁盘空间: 偏低 (${home_free}GB)，建议5GB+"
    else
        print_error "磁盘空间: 不足 (${home_free}GB)"
        return 1
    fi

    return 0
}

# -----------------------------------------------
# 检测现有安装状态
# -----------------------------------------------
detect_installation() {
    local info=""

    print_step "检测现有安装"

    # 检查应用目录
    if [ -d "$APP_DIR" ]; then
        info="${info}\n  - 应用目录存在: $APP_DIR"
    else
        info="${info}\n  - 应用目录: 不存在"
    fi

    # 检查JAR文件
    if [ -f "$APP_DIR/${JAR_FILE}" ]; then
        local jar_size
        jar_size=$(du -h "$APP_DIR/${JAR_FILE}" | cut -f1)
        info="${info}\n  - JAR已安装: $jar_size"
    else
        info="${info}\n  - JAR: 未安装"
    fi

    # 检查配置文件
    if [ -f "$APP_DIR/config/application.yml" ]; then
        info="${info}\n  - 配置文件: 存在"
    else
        info="${info}\n  - 配置文件: 不存在"
    fi

    # 检查systemd服务
    if systemctl list-unit-files 2>/dev/null | grep -q "${SERVICE_NAME}"; then
        if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
            info="${info}\n  - 服务状态: 运行中"
        else
            info="${info}\n  - 服务状态: 已停止"
        fi
    else
        info="${info}\n  - 服务: 未安装"
    fi

    echo -e "$info"
}

# -----------------------------------------------
# 运行所有环境检测
# -----------------------------------------------
run_all_checks() {
    local total_errors=0

    print_header "环境检测"
    echo

    # 注意: 使用 || true 避免 set -e 导致脚本退出
    check_root || true

    check_system; local e=$?; ((total_errors+=e)) || true
    check_java; local e=$?; ((total_errors+=e)) || true
    check_network; local e=$?; ((total_errors+=e)) || true
    check_vpn; local e=$?; ((total_errors+=e)) || true
    check_disk; local e=$?; ((total_errors+=e)) || true

    echo
    print_header "检测摘要"

    if [ "$total_errors" -eq 0 ]; then
        print_success "所有检测通过!"
    else
        print_warn "发现 $total_errors 个问题（不影响部署）"
    fi

    return 0
}
