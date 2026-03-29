#!/bin/bash
# =============================================================================
# JAR 下载与部署模块
# 处理从本地/Gitee/GitHub 获取并部署 JAR 文件
# =============================================================================

# -----------------------------------------------
# 全局变量：记录下载后的 JAR 文件路径
# -----------------------------------------------
DOWNLOADED_JAR_PATH=""

# -----------------------------------------------
# 获取最新发行版版本号
# 优先从 Gitee 获取，失败则尝试 GitHub
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
# 从发行版下载 JAR 文件
# 参数: $1 - 版本号
# 设置全局变量 DOWNLOADED_JAR_PATH 为下载文件路径
# -----------------------------------------------
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
# 部署 JAR 文件
# 搜索本地文件或从发行版下载，然后复制到应用目录
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
