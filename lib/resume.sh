#!/bin/bash
# =============================================================================
# 继续部署模块
# 支持断点续传，从上次中断的地方继续部署
# =============================================================================

# -----------------------------------------------
# 继续部署功能
# -----------------------------------------------
resume_deployment() {
    print_header "继续部署"

    # 检查状态文件是否存在
    if [ ! -f "$STATE_FILE" ]; then
        print_warn "没有找到部署状态文件，无法继续部署"
        print_info "请使用一键部署或手动部署开始新的部署"
        return 1
    fi

    local current_phase current_step status
    current_phase=$(get_state "PHASE")
    current_step=$(get_state "STEP")
    status=$(get_state "STATUS")

    echo
    print_info "上次部署状态:"
    echo "  阶段: $current_phase"
    echo "  步骤: $current_step"
    echo "  状态: $status"
    echo

    # 检查是否已完成
    if [ "$status" = "success" ]; then
        print_success "上次部署已成功完成"
        return 0
    fi

    # 检查是否失败
    if [ "$status" = "failed" ]; then
        local error
        error=$(get_state "ERROR_MSG")
        print_error "上次部署失败: $error"
        echo

        if confirm "回滚并重新开始?" "n"; then
            local snapshot
            snapshot=$(get_state "SNAPSHOT_BEFORE")
            if [ -n "$snapshot" ]; then
                rollback_to "$snapshot"
            fi
        fi
    fi

    # 询问是否继续
    if confirm "从上次中断的阶段继续?" "y"; then
        case $current_phase in
            PRECHECK)
                run_all_checks
                ;;
            PREPARE)
                create_dirs
                deploy_jar
                ;;
            DEPLOY)
                deploy_service
                start_service
                ;;
            CONFIG)
                run_config_wizard
                ;;
            *)
                print_warn "未知阶段，将执行完整部署"
                auto_deploy
                ;;
        esac
    fi
}
