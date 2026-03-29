# AGENTS.md

## Project Overview

Bash shell script project for automated deployment of **HCP Simulator Lite** (cloud charging station simulator) to Raspberry Pi 4B. Interactive deployment manager with modular architecture.

## Project Structure

```
raspberry-pi-deploy/
├── install.sh               # One-click install bootstrap script
├── deploy-interactive.sh    # Main entry point (set -uo pipefail)
├── docs/
│   └── DEPLOYMENT_GUIDE.md  # Detailed deployment guide
└── lib/
    ├── common.sh            # Utilities: logging, colors, user interaction
    ├── state.sh             # Deployment state management
    ├── env-check.sh         # Environment detection (OS, Java, network, disk)
    ├── mirror.sh            # Mirror source management (Aliyun, Tsinghua, USTC)
    ├── download.sh          # JAR download & deploy (local search, releases)
    ├── install.sh           # Main install flow (Java, dirs, config, service)
    ├── wireguard.sh         # WireGuard VPN setup
    ├── config.sh            # Configuration wizard (server, piles, VPN)
    ├── service.sh           # systemd service management
    ├── snapshot.sh          # Snapshot and rollback
    └── resume.sh            # Resume interrupted deployments
```

## Build, Lint & Test Commands

There is no automated test suite. Verification is done by running scripts interactively:

```bash
# Syntax check a single script
bash -n lib/common.sh

# Syntax check all scripts
for f in lib/*.sh deploy-interactive.sh; do bash -n "$f" && echo "$f OK"; done

# Lint with shellcheck (if installed)
shellcheck lib/*.sh deploy-interactive.sh

# Debug/trace mode
bash -x ./deploy-interactive.sh

# Run a single module for testing
source lib/common.sh && init_common
```

## Code Style Guidelines

### Shell Options
- `set -uo pipefail` at the top of entry scripts only — never in sourced lib files
- Do NOT use `set -e` — error handling is explicit via return codes

### File Header Format
```bash
#!/bin/bash
# =============================================================================
# 模块名称（中文描述）
# 说明该模块的职责
# =============================================================================
```

### Module Loading
- Load order in `deploy-interactive.sh`: common.sh → state.sh → env-check.sh → mirror.sh → download.sh → install.sh → wireguard.sh → config.sh → service.sh → snapshot.sh → resume.sh
- Precede each `source` with `# shellcheck source=/dev/null`

### Constants & Variables
- Global constants: `readonly UPPER_SNAKE_CASE` in `common.sh` (e.g., `APP_NAME`, `APP_DIR`, `SERVICE_NAME`)
- Module-local constants: `readonly` at top of module file (e.g., `WG_CONF_DIR` in wireguard.sh)
- `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` — use this pattern, not `$0`
- Always declare `local` at the top of functions; never use global mutable variables
- Temp files: use `$TEMP_DIR` (set to `/tmp/hcp-deploy-$$`)

### Naming Conventions
- Functions: `lower_snake_case` (e.g., `check_java`, `deploy_service`, `configure_vpn`)
- Utility prefix: `safe_` for input wrappers (`safe_read`, `safe_exec`, `safe_read_char`), `run_as_root` for privilege escalation
- Print functions (all in common.sh): `print_info`, `print_warn`, `print_error`, `print_success`, `print_step`, `print_header`

### Output & Logging
- All user-facing output through `print_*` functions — never raw `echo` for status messages
- Each `print_*` also writes to `~/.hcp-deploy.log` via `log "LEVEL" "msg"`
- Colors: `$RED`, `$GREEN`, `$YELLOW`, `$BLUE`, `$CYAN`, `$NC` (reset)

### User Interaction
- Always gate with `[[ -t 0 ]]` before `read` — non-interactive environments must have defaults
- `confirm "prompt?" "y|n"` — yes/no, returns 0/1
- `safe_read "prompt" "default"` — text input, echoes result
- `safe_read_char "prompt" var_name` — single-char menu selection

### Error Handling
- Functions return `0` success, `1` failure — always check `$?`
- `run_as_root cmd` — runs as root if `$EUID != 0`, otherwise runs directly (no sudo)
- `safe_exec "cmd" "error msg"` — wraps `eval`, prints error on failure
- Suppress intentional failures: `command 2>/dev/null || true`
- On deploy failure: `mark_failed "step_name" "reason"`, offer `rollback_prompt`

### Root Access & File Permissions
- `/etc/wireguard/` is typically `700` (root-only). **Always use `run_as_root test -f`** to check files there — plain `[ -f ... ]` fails for non-root users
- Same applies to any system path (`/etc/systemd/`, etc.): use `run_as_root` for file checks and reads
- Pattern: `if run_as_root test -f "$path"; then` NOT `if [ -f "$path" ]; then`

### Quoting & Expansion
- Double-quote all variable expansions: `"$APP_DIR"`, `"$1"`
- Arrays: `"${array[@]}"` for iteration
- Command substitution: `$()` not backticks
- Literal heredocs: `<< 'EOF'`; variable-expanding heredocs: `<< EOF`

### Conditionals
- `[[ ]]` for bash tests, `[ ]` only for POSIX compatibility
- Regex: `[[ "$var" =~ ^[0-9]{14}$ ]]`
- Command existence: `command_exists cmd_name` (wrapper in common.sh)

### Section Separators
- Logical blocks: `# ------` separator lines
- Announce major operations: `print_step "Description"`
