# AGENTS.md

## Project Overview

Bash shell script project for automated deployment of **HCP Simulator Lite** (cloud charging station simulator) to Raspberry Pi 4B. Interactive deployment manager with modular architecture.

## Project Structure

```
raspberry-pi-deploy/
├── install.sh               # One-click install bootstrap script
├── deploy-interactive.sh    # Main entry point
└── lib/
    ├── common.sh            # Utilities: logging, colors, user interaction
    ├── state.sh             # Deployment state management
    ├── env-check.sh         # Environment detection (OS, Java, network, disk)
    ├── mirror.sh            # Mirror source management (Aliyun, Tsinghua, USTC)
    ├── download.sh          # JAR download & deploy (local search, Gitee/GitHub releases)
    ├── install.sh           # Main install flow (Java, dirs, config, service)
    ├── config.sh            # Configuration wizard (server, piles, VPN)
    ├── service.sh           # systemd service management
    ├── snapshot.sh          # Snapshot and rollback
    ├── resume.sh            # Resume interrupted deployments
    └── wireguard.sh         # WireGuard VPN setup
```

## Running & Testing

There is no automated test suite or linting framework. Verification is done by running the scripts interactively:

```bash
# Run the deployment manager
./deploy-interactive.sh

# Run with bash strict mode (already set in scripts)
bash -x ./deploy-interactive.sh   # debug/trace mode

# Syntax check a single script
bash -n lib/common.sh

# Lint with shellcheck (if installed)
shellcheck lib/*.sh deploy-interactive.sh

# Run a single module for testing
source lib/common.sh && init_common
```

## Code Style Guidelines

### Shell Options
- Use `set -uo pipefail` at the top of entry scripts (not in sourced lib files)
- Do NOT use `set -e` — error handling is explicit via return codes

### Shebang & Header
- Every file starts with `#!/bin/bash`
- Follow with a `# ====` block header comment describing the module purpose

### File & Module Organization
- One module per file in `lib/`
- Load order matters: `common.sh` first, then others by dependency
- Source modules with `source "$lib_dir/module.sh"`; add `# shellcheck source=/dev/null` before sourcing

### Constants & Variables
- Global constants: `readonly UPPER_SNAKE_CASE` (e.g., `readonly APP_NAME="hcp-simulator-lite"`)
- Script dir: `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
- Local variables: `local` keyword always, declare at the top of each function
- Temp files: use `$TEMP_DIR` with `$$` suffix for uniqueness

### Naming Conventions
- Functions: `lower_snake_case` (e.g., `check_java`, `deploy_service`)
- Prefix helper/utility functions descriptively: `safe_read`, `safe_exec`, `run_as_root`
- Print functions: `print_info`, `print_warn`, `print_error`, `print_success`, `print_step`, `print_header`

### Output & Logging
- All user-facing output goes through `print_*` functions in `common.sh`
- Every `print_*` call also writes to the log file via `log "LEVEL" "message"`
- Use ANSI color codes via the defined constants: `$RED`, `$GREEN`, `$YELLOW`, `$BLUE`, `$CYAN`, `$NC`
- Log file: `~/.hcp-deploy.log`

### User Interaction
- Always check `[[ -t 0 ]]` for interactive terminal before `read`
- Provide non-interactive defaults for CI/piped execution
- Use `confirm "prompt?" "y|n"` for yes/no questions
- Use `safe_read "prompt" "default"` for text input
- Use `safe_read_char "prompt" var_name "default"` for single-char menus

### Error Handling
- Functions return `0` on success, `1` on failure — always check `$?`
- Use `safe_exec "command" "error message"` for wrapped execution
- Use `run_as_root` to conditionally add `sudo` based on `$EUID`
- On deployment failure: mark state with `mark_failed`, offer `rollback_prompt`
- Suppress errors with `2>/dev/null || true` only where intentional (e.g., status checks)

### Quoting & Expansion
- Always double-quote variables: `"$APP_DIR"`, `"$1"`
- Use `"${array[@]}"` for array iteration
- Prefer `$()` over backticks for command substitution
- Use `<<<` here-strings and `<< 'EOF'` (quoted) for literal heredocs; unquoted `<< EOF` for variable expansion

### Conditionals
- Use `[[ ]]` for bash-specific tests, `[ ]` for POSIX compatibility
- Pattern matching: `[[ "$var" =~ ^[0-9]{14}$ ]]`
- Command existence: `command_exists cmd_name` (wrapper in common.sh)

### Section Separators
- Use `# ------` blocks to separate logical sections within files
- Use `print_step "Description"` to announce major operations to the user
