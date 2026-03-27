#!/bin/bash
# =============================================================================
# 状态管理模块
# 管理部署状态文件，支持断点续传功能
# =============================================================================

# -----------------------------------------------
# 初始化状态文件
# -----------------------------------------------
init_state() {
    ensure_dir "$(dirname "$STATE_FILE")"
    ensure_dir "$BACKUP_DIR"

    cat > "$STATE_FILE" << EOF
DEPLOY_ID="$(get_timestamp)"
PHASE="INIT"
STEP=""
STATUS="init"
START_TIME="$(get_datetime)"
LAST_UPDATE="$(get_datetime)"
ERROR_MSG=""
SNAPSHOT_BEFORE=""
SNAPSHOT_AFTER=""
EOF

    log "STATE" "状态文件已初始化"
}

# -----------------------------------------------
# 更新状态值
# -----------------------------------------------
update_state() {
    local key="$1"
    local value="$2"

    # 确保状态文件存在
    if [ ! -f "$STATE_FILE" ]; then
        init_state
    fi

    if grep -q "^${key}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$STATE_FILE"
    else
        echo "${key}=\"${value}\"" >> "$STATE_FILE"
    fi
}

# -----------------------------------------------
# 获取状态值
# -----------------------------------------------
get_state() {
    local key="$1"

    if [ ! -f "$STATE_FILE" ]; then
        echo ""
        return 1
    fi

    grep "^${key}=" "$STATE_FILE" 2>/dev/null | cut -d'"' -f2
}

# -----------------------------------------------
# 标记步骤完成
# -----------------------------------------------
mark_complete() {
    local step="$1"
    update_state "STEP" "$step"
    update_state "STATUS" "success"
    update_state "LAST_UPDATE" "$(get_datetime)"
    print_success "步骤完成: $step"
}

# -----------------------------------------------
# 标记步骤失败
# -----------------------------------------------
mark_failed() {
    local step="$1"
    local error="${2:-未知错误}"
    update_state "STEP" "$step"
    update_state "STATUS" "failed"
    update_state "ERROR_MSG" "$error"
    update_state "LAST_UPDATE" "$(get_datetime)"
    print_error "步骤失败: $step - $error"
}

# -----------------------------------------------
# 检查是否有中断的部署
# -----------------------------------------------
has_interrupted_deployment() {
    if [ ! -f "$STATE_FILE" ]; then
        return 1
    fi

    local status
    status=$(get_state "STATUS")
    [[ "$status" == "failed" || "$status" == "running" ]]
}

# -----------------------------------------------
# 获取部署进度
# -----------------------------------------------
get_deployment_progress() {
    if [ ! -f "$STATE_FILE" ]; then
        echo "无部署记录"
        return
    fi

    local phase step status
    phase=$(get_state "PHASE")
    step=$(get_state "STEP")
    status=$(get_state "STATUS")

    echo "阶段: $phase | 步骤: $step | 状态: $status"
}
