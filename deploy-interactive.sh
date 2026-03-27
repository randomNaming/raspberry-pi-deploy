#!/bin/bash
#
# HCP Simulator Lite - 交互式部署脚本
# 适用于树莓派4B (Raspberry Pi OS 64-bit)
#
# 使用方法：
#   chmod +x deploy-interactive.sh
#   ./deploy-interactive.sh
#

set -euo pipefail

# ============================================
# 常量定义
# ============================================
readonly APP_NAME="hcp-simulator-lite"
readonly APP_DIR="${HOME}/${APP_NAME}"
readonly STATE_FILE="${HOME}/.hcp-deploy-state"
readonly LOG_FILE="${HOME}/.hcp-deploy.log"
readonly BACKUP_DIR="${HOME}/.hcp-deploy-backup"
readonly JAVA_MIN_VERSION=17
readonly JAR_FILE="${APP_NAME}.jar"
readonly SERVICE_NAME="${APP_NAME}.service"
readonly VPN_SERVICE="wg-quick@wg0.service"

# 脚本所在目录（兼容管道执行方式）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ============================================
# 颜色定义
# ============================================
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m'

# ============================================
# 工具函数
# ============================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

print_info() {
    echo -e "${GREEN}[信息]${NC} $*"
    log "INFO" "$*"
}

print_warn() {
    echo -e "${YELLOW}[警告]${NC} $*"
    log "WARN" "$*"
}

print_error() {
    echo -e "${RED}[错误]${NC} $*"
    log "ERROR" "$*"
}

print_success() {
    echo -e "${GREEN}[完成]${NC} $*"
    log "OK" "$*"
}

print_step() {
    echo
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  步骤: $*${NC}"
    echo -e "${CYAN}========================================${NC}"
    log "STEP" "$*"
}

print_header() {
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $*${NC}"
    echo -e "${BLUE}========================================${NC}"
}

print_subheader() {
    echo
    echo -e "${MAGENTA}--- $* ---${NC}"
}

# 确认操作
confirm() {
    local prompt="${1:-继续?}"
    local default="${2:-y}"

    if [ "$default" = "y" ]; then
        read -p "$prompt [Y/n]: " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Nn]$ ]]
    else
        read -p "$prompt [y/N]: " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]]
    fi
}

# 暂停等待
pause() {
    print_info "按回车键继续..."
    read -r
}

# ============================================
# 状态管理
# ============================================

init_state() {
    mkdir -p "$(dirname "$STATE_FILE")"
    mkdir -p "$BACKUP_DIR"

    cat > "$STATE_FILE" << EOF
DEPLOY_ID="$(date '+%Y%m%d-%H%M%S')"
PHASE="INIT"
STEP=""
STATUS="init"
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
LAST_UPDATE="$(date '+%Y-%m-%d %H:%M:%S')"
ERROR_MSG=""
SNAPSHOT_BEFORE=""
SNAPSHOT_AFTER=""
EOF

    log "STATE" "状态文件已初始化"
}

update_state() {
    local key="$1"
    local value="$2"

    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$STATE_FILE"
    else
        echo "${key}=\"${value}\"" >> "$STATE_FILE"
    fi
}

get_state() {
    local key="$1"
    grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'"' -f2
}

mark_complete() {
    local step="$1"
    update_state "STEP" "$step"
    update_state "STATUS" "success"
    update_state "LAST_UPDATE" "$(date '+%Y-%m-%d %H:%M:%S')"
    print_success "步骤完成: $step"
}

mark_failed() {
    local step="$1"
    local error="${2:-未知错误}"
    update_state "STEP" "$step"
    update_state "STATUS" "failed"
    update_state "ERROR_MSG" "$error"
    update_state "LAST_UPDATE" "$(date '+%Y-%m-%d %H:%M:%S')"
    print_error "步骤失败: $step - $error"
}

# ============================================
# 快照与回滚
# ============================================

create_snapshot() {
    local snapshot_id="$(date '%Y%m%d-%H%M%S')"
    local snapshot_dir="${BACKUP_DIR}/${snapshot_id}"

    mkdir -p "$snapshot_dir"

    # 备份配置
    if [ -d "$APP_DIR/config" ]; then
        cp -r "$APP_DIR/config" "$snapshot_dir/"
    fi

    # 备份JAR（如果存在）
    if [ -f "$APP_DIR/${JAR_FILE}" ]; then
        cp "$APP_DIR/${JAR_FILE}" "$snapshot_dir/"
    fi

    # 备份systemd服务
    if [ -f "/etc/systemd/system/${SERVICE_NAME}" ]; then
        cp "/etc/systemd/system/${SERVICE_NAME}" "$snapshot_dir/"
    fi

    # 保存快照ID
    echo "$snapshot_id" > "$snapshot_dir/id"

    update_state "SNAPSHOT_BEFORE" "$snapshot_id"
    print_info "快照已创建: $snapshot_id"

    echo "$snapshot_id"
}

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
    sudo systemctl stop "${APP_NAME}" 2>/dev/null || true

    # 恢复配置
    if [ -d "$snapshot_dir/config" ]; then
        mkdir -p "$APP_DIR/config"
        cp -r "$snapshot_dir/config/"* "$APP_DIR/config/" 2>/dev/null || true
    fi

    # 恢复JAR
    if [ -f "$snapshot_dir/${JAR_FILE}" ]; then
        cp "$snapshot_dir/${JAR_FILE}" "$APP_DIR/" 2>/dev/null || true
    fi

    # 恢复服务
    if [ -f "$snapshot_dir/${SERVICE_NAME}" ]; then
        sudo cp "$snapshot_dir/${SERVICE_NAME}" "/etc/systemd/system/${SERVICE_NAME}"
        sudo systemctl daemon-reload
    fi

    # 重启服务
    sudo systemctl start "${APP_NAME}" 2>/dev/null || true

    print_success "回滚完成"
}

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
            local id=$(basename "$dir")
            local created=$(stat -c %y "$dir" 2>/dev/null | cut -d' ' -f1,2 || echo "未知")
            local contents=""
            [ -d "$dir/config" ] && contents="${contents}配置 "
            [ -f "$dir/${JAR_FILE}" ] && contents="${contents}JAR "
            [ -f "$dir/${SERVICE_NAME}" ] && contents="${contents}服务"
            printf "%-20s %-25s %s\n" "$id" "$created" "$contents"
        fi
    done
}

# ============================================
# 环境检测
# ============================================

check_root() {
    if [ "$EUID" -eq 0 ]; then
        print_warn "不建议使用root用户运行此脚本，请使用普通用户"
        return 1
    fi
    return 0
}

check_system() {
    print_step "检测系统"

    local errors=0

    # OS检查
    print_info "检查操作系统..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" == "raspbian" || "$ID" == "debian" ]]; then
            print_success "操作系统: $PRETTY_NAME"
        else
            print_warn "操作系统: $PRETTY_NAME (非Raspbian/Debian)"
        fi
    else
        print_error "无法检测操作系统"
        ((errors++))
    fi

    # 架构检查
    print_info "检查架构..."
    local arch=$(uname -m)
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        print_success "架构: $arch"
    else
        print_error "不支持的架构: $arch"
        ((errors++))
    fi

    # 内存检查
    print_info "检查内存..."
    local mem_total=$(free -m | awk '/^Mem:/{print $2}')
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

check_java() {
    print_step "检测Java"

    if ! command -v java &>/dev/null; then
        print_error "Java未安装"
        return 1
    fi

    local java_ver=$(java -version 2>&1 | head -1 | cut -d'"' -f2)
    local major=$(echo "$java_ver" | cut -d'.' -f1 | sed 's/[^0-9]//g')

    if [ "$major" -ge "$JAVA_MIN_VERSION" ]; then
        print_success "Java版本: $java_ver"
    else
        print_error "Java版本过低: $java_ver (需要${JAVA_MIN_VERSION}+)"
        return 1
    fi

    if [ -n "$JAVA_HOME" ]; then
        print_info "JAVA_HOME: $JAVA_HOME"
    else
        print_warn "JAVA_HOME未设置"
    fi

    return 0
}

check_network() {
    print_step "检测网络"

    local errors=0

    # 网络连接
    print_info "检查网络连接..."
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        print_success "网络: 已连接"
    else
        print_error "网络: 无法访问"
        ((errors++))
    fi

    # DNS解析
    print_info "检查DNS..."
    if host google.com &>/dev/null || nslookup google.com &>/dev/null; then
        print_success "DNS: 正常"
    else
        print_error "DNS: 异常"
        ((errors++))
    fi

    return $errors
}

check_vpn() {
    print_step "检测WireGuard VPN"

    # 检查VPN服务是否存在
    if ! systemctl list-unit-files | grep -q "$VPN_SERVICE"; then
        print_warn "WireGuard服务未配置"
        return 0  # VPN可选，不算错误
    fi

    # 检查VPN是否激活
    if systemctl is-active --quiet "$VPN_SERVICE"; then
        print_success "WireGuard VPN: 已激活"

        # 获取VPN IP
        local vpn_ip=$(ip addr show wg0 2>/dev/null | grep inet | awk '{print $2}' | cut -d'/' -f1)
        if [ -n "$vpn_ip" ]; then
            print_info "VPN IP: $vpn_ip"
        fi
    else
        print_warn "WireGuard VPN: 未激活 (可选，不影响部署)"
    fi

    return 0
}

check_disk() {
    print_step "检测磁盘空间"

    local home_free=$(df -BG "$HOME" | awk 'NR==2 {print $4}' | tr -d 'G')

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

detect_installation() {
    local info=""

    print_step "检测现有安装"

    # 检查应用目录
    if [ -d "$APP_DIR" ]; then
        info="${info}\n  - 应用目录存在: $APP_DIR"
    else
        info="${info}\n  - 应用目录: 不存在"
    fi

    # 检查JAR
    if [ -f "$APP_DIR/${JAR_FILE}" ]; then
        local jar_size=$(du -h "$APP_DIR/${JAR_FILE}" | cut -f1)
        info="${info}\n  - JAR已安装: $jar_size"
    else
        info="${info}\n  - JAR: 未安装"
    fi

    # 检查配置
    if [ -f "$APP_DIR/config/application.yml" ]; then
        info="${info}\n  - 配置文件: 存在"
    else
        info="${info}\n  - 配置文件: 不存在"
    fi

    # 检查服务
    if systemctl list-unit-files | grep -q "${SERVICE_NAME}"; then
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            info="${info}\n  - 服务状态: 运行中"
        else
            info="${info}\n  - 服务状态: 已停止"
        fi
    else
        info="${info}\n  - 服务: 未安装"
    fi

    echo -e "$info"
}

run_all_checks() {
    local total_errors=0

    print_header "环境检测"
    echo

    check_root || true
    check_system || ((total_errors+=$?))
    check_java || ((total_errors+=$?))
    check_network || ((total_errors+=$?))
    check_vpn || ((total_errors+=$?))
    check_disk || ((total_errors+=$?))

    echo
    print_header "检测摘要"

    if [ $total_errors -eq 0 ]; then
        print_success "所有检测通过!"
        return 0
    else
        print_error "发现 $total_errors 个问题"
        return $total_errors
    fi
}

# ============================================
# 安装函数
# ============================================

install_java() {
    print_step "安装Java"

    if command -v java &>/dev/null; then
        local java_ver=$(java -version 2>&1 | head -1)
        print_info "Java已安装: $java_ver"
        if confirm "重新安装Java?" "n"; then
            sudo apt install -y openjdk-${JAVA_MIN_VERSION}-jdk
        fi
    else
        print_info "安装OpenJDK ${JAVA_MIN_VERSION}..."
        sudo apt update
        sudo apt install -y openjdk-${JAVA_MIN_VERSION}-jdk
    fi

    if command -v java &>/dev/null; then
        print_success "Java安装完成"
        return 0
    else
        print_error "Java安装失败"
        return 1
    fi
}

create_dirs() {
    print_step "创建目录"

    mkdir -p "$APP_DIR"/{data,logs,config}
    print_success "目录创建完成: $APP_DIR"
    print_info "  - data/"
    print_info "  - logs/"
    print_info "  - config/"

    return 0
}

deploy_jar() {
    print_step "部署JAR文件"

    local jar_path=""

    # 搜索JAR文件
    for dir in "$SCRIPT_DIR" "$HOME" "." "/tmp"; do
        if [ -f "$dir/${JAR_FILE}" ]; then
            jar_path="$dir/${JAR_FILE}"
            break
        fi
    done

    if [ -z "$jar_path" ]; then
        print_error "未找到JAR文件: ${JAR_FILE}"
        print_info "请将JAR文件放置到以下位置之一:"
        print_info "  - 脚本目录: $SCRIPT_DIR"
        print_info "  - home目录: $HOME"
        print_info "  - 当前目录: $(pwd)"
        read -p "或输入JAR文件路径: " jar_path
    fi

    if [ ! -f "$jar_path" ]; then
        print_error "文件不存在: $jar_path"
        return 1
    fi

    print_info "源文件: $jar_path"
    print_info "目标: $APP_DIR/${JAR_FILE}"

    cp "$jar_path" "$APP_DIR/${JAR_FILE}"
    chmod +x "$APP_DIR/${JAR_FILE}"
    chown -R $(whoami):$(id -gn) "$APP_DIR/${JAR_FILE}"

    print_success "JAR部署完成"
    return 0
}

deploy_config() {
    print_step "部署配置文件"

    local config_path=""

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
    chown $(whoami):$(id -gn) "$APP_DIR/config/application.yml"

    print_success "配置部署完成"
    return 0
}

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
    print_info "默认配置文件已创建: $APP_DIR/config/application.yml"
    print_warn "请根据实际情况修改配置文件中的桩信息"
}

deploy_service() {
    print_step "部署Systemd服务"

    # 创建服务文件
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

    echo "$service_content" | sudo tee "/etc/systemd/system/${SERVICE_NAME}" > /dev/null

    sudo systemctl daemon-reload
    sudo systemctl enable "${SERVICE_NAME}"

    print_success "服务部署完成"
    return 0
}

start_service() {
    print_step "启动服务"

    sudo systemctl daemon-reload
    sudo systemctl enable "${SERVICE_NAME}"
    sudo systemctl restart "${SERVICE_NAME}"
    sleep 3

    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        print_success "服务启动成功"
        return 0
    else
        print_error "服务启动失败"
        print_info "查看日志: sudo journalctl -u ${SERVICE_NAME} -n 50"
        return 1
    fi
}

# ============================================
# 配置向导
# ============================================

configure_server() {
    print_step "配置服务器"

    local host port protocol software

    # 读取当前值
    if [ -f "$APP_DIR/config/application.yml" ]; then
        host=$(grep "host:" "$APP_DIR/config/application.yml" | head -1 | awk '{print $2}' | tr -d '"')
        port=$(grep -A1 "server:" "$APP_DIR/config/application.yml" | grep "port:" | grep -v "server.port" | head -1 | awk '{print $2}' | tr -d '"')
        protocol=$(grep "protocol-version:" "$APP_DIR/config/application.yml" | awk '{print $2}' | tr -d '"')
        software=$(grep "software-version:" "$APP_DIR/config/application.yml" | awk '{print $2}' | tr -d '"')
    fi

    # 默认值
    host=${host:-121.43.69.62}
    port=${port:-8767}
    protocol=${protocol:-V160}
    software=${software:-V1.6.0}

    echo
    echo -e "${YELLOW}当前值在方括号中，直接回车使用默认值${NC}"
    echo

    read -p "服务器地址 [$host]: " input && [ -n "$input" ] && host="$input"
    read -p "服务器端口 [$port]: " input && [ -n "$input" ] && port="$input"
    read -p "协议版本(V150/V160/V170) [$protocol]: " input && [ -n "$input" ] && protocol="$input"
    read -p "软件版本 [$software]: " input && [ -n "$input" ] && software="$input"

    echo "$host:$port:$protocol:$software" > /tmp/hcp-server-config
}

configure_piles() {
    print_step "配置桩"

    local piles=()
    local guns=()

    while true; do
        echo
        print_info "添加桩（14位编号，空回车结束）:"
        read -p "桩编号: " pile_code

        if [ -z "$pile_code" ]; then
            break
        fi

        if ! [[ "$pile_code" =~ ^[0-9]{14}$ ]]; then
            print_error "桩编号必须是14位数字"
            continue
        fi

        read -p "枪号(空格分隔，默认: 01 02): " gun_input
        gun_input=${gun_input:-"01 02"}

        piles+=("$pile_code")
        guns+=("$gun_input")

        print_success "已添加: $pile_code - 枪号: $gun_input"
    done

    if [ ${#piles[@]} -eq 0 ]; then
        print_warn "未配置桩，将使用默认值"
        piles=("32010601122277" "32010601122278")
        guns=("01 02" "01 02")
    fi

    printf '%s\n' "${piles[@]}" > /tmp/hcp-piles
    printf '%s\n' "${guns[@]}" > /tmp/hcp-guns
}

configure_vpn() {
    print_step "配置VPN (可选)"

    local vpn_ip sim_id

    if [ -f "/etc/systemd/system/${SERVICE_NAME}" ]; then
        vpn_ip=$(grep "SPRING_CLOUD_NACOS_DISCOVERY_IP" /etc/systemd/system/${SERVICE_NAME} | cut -d'"' -f2)
        sim_id=$(grep "SIMULATOR_INSTANCE_ID" /etc/systemd/system/${SERVICE_NAME} | cut -d'"' -f2)
    fi

    vpn_ip=${vpn_ip:-10.0.0.2}
    sim_id=${sim_id:-pi-01}

    echo
    read -p "VPN IP地址 [$vpn_ip]: " input && [ -n "$input" ] && vpn_ip="$input"
    read -p "实例ID [$sim_id]: " input && [ -n "$input" ] && sim_id="$input"

    echo "$vpn_ip:$sim_id" > /tmp/hcp-vpn-config
}

save_config() {
    print_step "保存配置"

    # 读取服务器配置
    local server_config
    server_config=$(cat /tmp/hcp-server-config 2>/dev/null || echo "121.43.69.62:8767:V160:V1.6.0")
    IFS=':' read -r ykc_host ykc_port protocol_version software_version <<< "$server_config"

    # 生成YAML
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

    # 添加桩配置
    local pile_arrays=()
    local i=0
    for pile in "${piles[@]}"; do
        local guns="${guns[$i]}"
        echo "    - pile-code: \"$pile\"" >> "$APP_DIR/config/application.yml"
        # 转换空格分隔的枪号为YAML数组
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
        ((i++))
    done

    chown $(whoami):$(id -gn) "$APP_DIR/config/application.yml"

    # 更新systemd服务中的VPN配置
    local vpn_config
    vpn_config=$(cat /tmp/hcp-vpn-config 2>/dev/null || echo "10.0.0.2:pi-01")
    IFS=':' read -r vpn_ip sim_id <<< "$vpn_config"

    sudo sed -i "s|Environment=\"SPRING_CLOUD_NACOS_DISCOVERY_IP=.*\"|Environment=\"SPRING_CLOUD_NACOS_DISCOVERY_IP=$vpn_ip\"|" \
        /etc/systemd/system/${SERVICE_NAME} 2>/dev/null || true
    sudo sed -i "s|Environment=\"SIMULATOR_INSTANCE_ID=.*\"|Environment=\"SIMULATOR_INSTANCE_ID=$sim_id\"|" \
        /etc/systemd/system/${SERVICE_NAME} 2>/dev/null || true

    sudo systemctl daemon-reload

    print_success "配置已保存"

    # 清理临时文件
    rm -f /tmp/hcp-server-config /tmp/hcp-piles /tmp/hcp-guns /tmp/hcp-vpn-config
}

run_config_wizard() {
    print_header "配置向导"

    # 读取现有配置
    if [ -f "$APP_DIR/config/application.yml" ]; then
        print_info "检测到现有配置，是否修改?"
        if ! confirm "修改配置?" "n"; then
            return 0
        fi
    fi

    configure_server
    configure_piles
    configure_vpn
    save_config

    print_success "配置完成!"
}

# ============================================
# 一键自动部署
# ============================================

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
    local snapshot_id=$(create_snapshot)
    echo

    # 步骤3: 安装Java
    ((current_step++))
    print_step "步骤 $current_step/$total_steps: Java安装"

    if ! check_java &>/dev/null; then
        print_info "正在安装Java..."
        sudo apt update
        sudo apt install -y openjdk-${JAVA_MIN_VERSION}-jdk

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

rollback_prompt() {
    local snapshot_id="$1"

    echo
    if confirm "回滚到之前的状态?" "y"; then
        rollback_to "$snapshot_id"
    else
        print_warn "未执行回滚，系统可能处于不一致状态"
    fi
}

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

# ============================================
# 手动部署
# ============================================

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
                status="${GREEN}[完成]${NC}"
            elif [[ " ${failed[*]} " =~ " $i " ]]; then
                status="${RED}[失败]${NC}"
            fi
            printf "  [%d] %-20s %s\n" "$num" "${options[$i]}" "$status"
        done

        echo
        read -p "选择步骤 [1-${#options[@]}]: " -n 1 -r choice
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
            *)  print_error "无效选择" ;;
        esac

        if [ $result -eq 0 ]; then
            completed+=("$((choice-1))")
        else
            failed+=("$((choice-1))")
        fi

        # 检查是否全部完成
        if [ ${#completed[@]} -eq 7 ]; then
            echo
            print_success "所有部署步骤完成!"
            break
        fi
    done
}

verify_deployment() {
    print_step "验证部署"

    echo
    print_info "1. 检查服务状态..."
    sudo systemctl status "${SERVICE_NAME}" --no-pager -l || true

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
    print_info "4. 检查网络连通性..."
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:18080/actuator/health" 2>/dev/null | grep -q "200"; then
        print_success "应用响应正常"
    else
        print_warn "应用可能尚未响应"
    fi

    return 0
}

# ============================================
# 镜像接管
# ============================================

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
    read -p "选择 [1-${#options[@]}]: " -n 1 -r choice
    echo

    case $choice in
        1) scan_installation ;;
        2) backup_current ;;
        3) update_app_only ;;
        4) reset_config ;;
        5) full_reinstall ;;
        6) restore_backup ;;
        7) return 0 ;;
        *) print_error "无效选择" ;;
    esac
}

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
    sudo systemctl status "${SERVICE_NAME}" --no-pager -l || true
}

backup_current() {
    print_step "备份当前状态"

    local snapshot_id=$(create_snapshot)
    print_success "快照已创建: $snapshot_id"

    # 创建完整备份
    local backup_file="${HOME}/hcp-backup-$(date '+%Y%m%d-%H%M%S').tar.gz"

    tar -czf "$backup_file" \
        -C "$APP_DIR" . \
        -C "$(dirname "$STATE_FILE")" .hcp-deploy-state \
        /etc/systemd/system/${SERVICE_NAME} 2>/dev/null || true

    print_success "完整备份: $backup_file"
}

update_app_only() {
    print_step "仅更新应用"

    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        print_info "停止服务..."
        sudo systemctl stop "${SERVICE_NAME}"
    fi

    deploy_jar

    print_info "启动服务..."
    sudo systemctl start "${SERVICE_NAME}"
}

reset_config() {
    print_step "重置配置"

    if confirm "重置为默认配置?" "n"; then
        create_snapshot
        create_default_config
        print_success "配置已重置为默认值"
        print_info "请使用配置管理重新配置"
    fi
}

full_reinstall() {
    print_step "完全重装"

    print_warn "这将重新安装所有内容!"
    if ! confirm "继续完全重装?" "n"; then
        return
    fi

    # 先备份
    backup_current

    # 停止服务
    sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

    # 移除服务
    sudo rm -f /etc/systemd/system/${SERVICE_NAME}
    sudo systemctl daemon-reload

    # 全新部署
    auto_deploy
}

restore_backup() {
    print_step "从备份恢复"

    list_snapshots
    echo

    read -p "输入快照ID进行恢复: " snapshot_id
    if [ -n "$snapshot_id" ]; then
        rollback_to "$snapshot_id"
    fi
}

# ============================================
# 继续部署
# ============================================

resume_deployment() {
    print_header "继续部署"

    local current_phase=$(get_state "PHASE")
    local current_step=$(get_state "STEP")
    local status=$(get_state "STATUS")

    echo
    print_info "上次部署状态:"
    echo "  阶段: $current_phase"
    echo "  步骤: $current_step"
    echo "  状态: $status"
    echo

    if [ "$status" = "success" ]; then
        print_success "上次部署已成功完成"
        return
    fi

    if [ "$status" = "failed" ]; then
        local error=$(get_state "ERROR_MSG")
        print_error "上次部署失败: $error"
        echo

        if confirm "回滚并重新开始?" "n"; then
            local snapshot=$(get_state "SNAPSHOT_BEFORE")
            if [ -n "$snapshot" ]; then
                rollback_to "$snapshot"
            fi
        fi
    fi

    if confirm "从上次中断的阶段继续?" "y"; then
        case $current_phase in
            PRECHECK) run_all_checks ;;
            PREPARE)  create_dirs; deploy_jar ;;
            DEPLOY)   deploy_service; start_service ;;
            *)        auto_deploy ;;
        esac
    fi
}

# ============================================
# 服务管理
# ============================================

service_menu() {
    while true; do
        echo
        print_header "服务管理"
        echo

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
        read -p "选择 [1-${#options[@]}]: " -n 1 -r choice
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
            *) print_error "无效选择" ;;
        esac
    done
}

service_status() {
    echo
    sudo systemctl status "${SERVICE_NAME}" --no-pager -l
}

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

service_logs_live() {
    print_info "按Ctrl+C退出日志查看"
    sudo journalctl -u "${SERVICE_NAME}" -f
}

service_logs_recent() {
    local lines=${1:-50}
    sudo journalctl -u "${SERVICE_NAME}" -n "$lines"
}

service_enable() {
    sudo systemctl enable "${SERVICE_NAME}"
    print_success "服务已启用开机启动"
}

service_disable() {
    sudo systemctl disable "${SERVICE_NAME}"
    print_success "服务已禁用开机启动"
}

# ============================================
# 回滚
# ============================================

show_rollback_menu() {
    print_header "回滚"

    list_snapshots
    echo

    if confirm "执行回滚?" "n"; then
        read -p "输入快照ID: " snapshot_id
        if [ -n "$snapshot_id" ]; then
            rollback_to "$snapshot_id"
        fi
    fi
}

# ============================================
# 查看日志
# ============================================

view_logs() {
    print_header "部署日志"

    if [ -f "$LOG_FILE" ]; then
        tail -100 "$LOG_FILE"
    else
        print_warn "未找到日志文件"
    fi
}

# ============================================
# 主菜单
# ============================================

main_menu() {
    while true; do
        clear
        echo
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}  HCP Simulator Lite${NC}"
        echo -e "${BLUE}  交互式部署管理器${NC}"
        echo -e "${BLUE}  树莓派4B版${NC}"
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

        read -p "  选择 [0-9]: " -n 1 -r choice
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
            0) exit_menu ;;
            *) print_error "无效选择" ;;
        esac

        if [ "$choice" != "0" ]; then
            pause
        fi
    done
}

exit_menu() {
    echo
    print_info "再见!"
    exit 0
}

# ============================================
# 主程序
# ============================================

main() {
    # 确保目录存在
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true

    # 初始化状态
    init_state 2>/dev/null || true

    # 显示欢迎信息
    print_header "HCP Simulator Lite 部署管理器"
    print_info "目标平台: 树莓派4B (Raspberry Pi OS)"
    print_info "应用: $APP_NAME"
    echo

    # 检查运行环境
    if ! check_root; then
        print_warn "继续执行，但建议使用普通用户"
    fi

    # 运行主菜单
    main_menu
}

# 执行主程序
main
