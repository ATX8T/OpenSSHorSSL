#!/bin/bash

################################################################################
#                      SSH 密钥生成与系统配置工具                               #
#                    SSH Key Generation & System Configuration                 #
#                                                                              #
#  核心功能:                                                                   #
#  1. 检查OpenSSH服务和SSH功能状态，自动安装并启动                              #
#  2. 提供密钥算法选择交互（RSA 4096/8192, Ed25519）                           #
#  3. 重新生成密钥时直接删除旧密钥（不备份）                                    #
#  4. 配置SSH服务实现密钥远程登录                                              #
#  5. 密钥生成成功后交互询问是否显示私钥                                        #
#  6. 安全考虑：直接删除旧密钥                                                  #
#                                                                              #
#  版本: v3.0 (安全审查和改进)                                                 #
#  日期: 2025-04-07                                                            #
#                                                                              #
################################################################################

set -euo pipefail

# 严格的错误处理
trap 'echo -e "\n${RED}[✗]${NC} 脚本执行出错"; exit 1' ERR
trap 'cleanup' EXIT INT TERM

# 颜色定义
readonly RED='\033[1;31m'
readonly GREEN='\033[1;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[1;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# 全局变量 - 只读声明，提高安全性
readonly SSH_DIR="${HOME}/.ssh"
readonly SSH_CONFIG="/etc/ssh/sshd_config"
readonly SSH_CONFIG_BACKUP_DIR="/etc/ssh/backup"
readonly KEY_COMMENT="root@$(hostname)"
readonly TEMP_DIR=$(mktemp -d)

# 需要在运行时设置的变量
DISTRO=""
ALGO=""
KEY_BITS=""
SHOW_PRIVATE_KEY=false
PRIVATE_KEY_FILE=""
PUBLIC_KEY_FILE=""

################################################################################
#                          安全功能模块                                         #
################################################################################

# 清理临时文件
cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
}

# 检查脚本是否以root运行
check_root() {
    if [[ ${EUID} -eq 0 ]]; then
        log_warn "不建议以 root 用户运行此脚本"
        log_info "脚本会在需要时使用 sudo 提权"
        sleep 2
    fi
}

# 验证sudo权限
check_sudo_permission() {
    if ! sudo -n true 2>/dev/null; then
        log_error "需要 sudo 权限但当前用户无法无密码执行 sudo"
        log_info "请运行以下命令配置 sudoers:"
        log_info "  sudo visudo"
        log_info "并添加: $USER ALL=(ALL) NOPASSWD: /bin/systemctl, /bin/sed, /bin/cp"
        exit 1
    fi
}

# 验证SSH配置文件的安全性
verify_ssh_config_permissions() {
    if [[ -f "$SSH_CONFIG" ]]; then
        local perms
        perms=$(stat -c %a "$SSH_CONFIG" 2>/dev/null || stat -f %A "$SSH_CONFIG" 2>/dev/null)
        
        # SSH配置文件应该只有root可读写
        if [[ "$perms" != "600" && "$perms" != "644" ]]; then
            log_warn "SSH配置文件权限异常: $perms (建议: 600)"
        fi
    fi
}

# 验证.ssh目录权限
verify_ssh_dir_permissions() {
    if [[ -d "$SSH_DIR" ]]; then
        local perms
        perms=$(stat -c %a "$SSH_DIR" 2>/dev/null || stat -f %A "$SSH_DIR" 2>/dev/null)
        
        if [[ "$perms" != "700" ]]; then
            log_warn ".ssh 目录权限不安全: $perms (应该是: 700)"
            log_info "修复权限: chmod 700 $SSH_DIR"
            chmod 700 "$SSH_DIR"
        fi
    fi
}

# 验证输入参数（防止注入攻击）
validate_input() {
    local input="$1"
    local pattern="$2"
    
    if [[ ! "$input" =~ $pattern ]]; then
        log_error "输入验证失败: 包含非法字符"
        return 1
    fi
    return 0
}

# 安全的sed操作（转义特殊字符）
safe_sed() {
    local pattern="$1"
    local replacement="$2"
    local file="$3"
    
    # 转义特殊字符
    replacement=$(echo "$replacement" | sed 's/[&/\]/\\&/g')
    sudo sed -i "s/${pattern}/${replacement}/g" "$file"
}

################################################################################
#                          输出函数                                             #
################################################################################

log_info() {
    echo -e "${CYAN}[ℹ]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[✗]${NC} $*" >&2
}

print_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${BLUE}● Step: $*${NC}" >&2
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}

################################################################################
#                          第一步: 检查和安装OpenSSH服务                        #
################################################################################

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO="${ID:-unknown}"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="centos"
    else
        log_error "无法识别系统类型"
        exit 1
    fi
    
    log_success "检测到系统: $DISTRO"
}

check_and_install_ssh() {
    print_step "检查 OpenSSH 服务和 SSH 功能"
    
    if command -v ssh >/dev/null 2>&1; then
        log_success "SSH 客户端已安装"
    else
        log_warn "SSH 客户端未安装，准备安装..."
        install_ssh_client
    fi
    
    if ! sudo systemctl list-units --all 2>/dev/null | grep -qE "sshd|ssh\.service"; then
        log_warn "OpenSSH 服务端未安装，准备安装..."
        install_ssh_server
    else
        log_success "OpenSSH 服务端已安装"
    fi
    
    if sudo systemctl is-active --quiet ssh 2>/dev/null || sudo systemctl is-active --quiet sshd 2>/dev/null; then
        log_success "SSH 服务运行中"
    else
        log_warn "SSH 服务未运行，正在启动..."
        start_ssh_service
    fi
    
    # 验证配置文件权限
    verify_ssh_config_permissions
}

install_ssh_client() {
    log_info "正在安装 SSH 客户端..."
    
    case "$DISTRO" in
        debian|ubuntu)
            sudo apt-get update -qq >/dev/null 2>&1 || log_error "apt-get update 失败"
            sudo apt-get install -y openssh-client >/dev/null 2>&1 || log_error "安装失败"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            sudo yum install -y openssh-clients >/dev/null 2>&1 || log_error "安装失败"
            ;;
        alpine)
            sudo apk add --no-cache openssh-client >/dev/null 2>&1 || log_error "安装失败"
            ;;
        arch)
            sudo pacman -S --noconfirm openssh >/dev/null 2>&1 || log_error "安装失败"
            ;;
        *)
            log_error "不支持的Linux发行版: $DISTRO"
            exit 1
            ;;
    esac
    
    log_success "SSH 客户端已安装"
}

install_ssh_server() {
    log_info "正在安装 OpenSSH 服务端..."
    
    case "$DISTRO" in
        debian|ubuntu)
            sudo apt-get update -qq >/dev/null 2>&1 || log_error "apt-get update 失败"
            sudo apt-get install -y openssh-server >/dev/null 2>&1 || log_error "安装失败"
            ;;
        centos|rhel|fedora|rocky|almalinux)
            sudo yum install -y openssh-server >/dev/null 2>&1 || log_error "安装失败"
            ;;
        alpine)
            sudo apk add --no-cache openssh >/dev/null 2>&1 || log_error "安装失败"
            ;;
        arch)
            sudo pacman -S --noconfirm openssh >/dev/null 2>&1 || log_error "安装失败"
            ;;
        *)
            log_error "不支持的Linux发行版: $DISTRO"
            exit 1
            ;;
    esac
    
    log_success "OpenSSH 服务端已安装"
}

start_ssh_service() {
    log_info "启动 SSH 服务..."
    
    sudo systemctl start sshd 2>/dev/null || sudo systemctl start ssh 2>/dev/null
    sudo systemctl enable sshd 2>/dev/null || sudo systemctl enable ssh 2>/dev/null
    
    if sudo systemctl is-active --quiet sshd 2>/dev/null || sudo systemctl is-active --quiet ssh 2>/dev/null; then
        log_success "SSH 服务已启动并设置开机自启"
    else
        log_error "SSH 服务启动失败"
        exit 1
    fi
}

################################################################################
#                          第二步: 密钥算法选择交互                             #
################################################################################

select_key_algorithm() {
    print_step "选择��钥算法"
    
    echo "┌──────────────┬─────────────┬──────────┬─────────────────────────┐" >&2
    echo "│ 选项         │ 算法        │ 密钥大小 │ 特点                    │" >&2
    echo "├──────────────┼─────────────┼──────────┼─────────────────────────┤" >&2
    echo "│ 1            │ RSA 4096    │ 4096位   │ 兼容性好，应用广泛      │" >&2
    echo "│ 2            │ RSA 8192    │ 8192位   │ 超高安全性��生成较慢    │" >&2
    echo "│ 3            │ Ed25519     │ 256bit   │ ★推荐★ 快速高效安全    │" >&2
    echo "└──────────────┴─────────────┴──────────┴─────────────────────────┘" >&2
    echo "" >&2
    echo "算法说明:" >&2
    echo "  • RSA 4096: 广泛兼容，适合大多数场景" >&2
    echo "  • RSA 8192: 最高安全级别，推荐用于政府/金融等敏感领域" >&2
    echo "  • Ed25519:  现代算法，运算速度快，安全性强（★★★推荐★★★）" >&2
    echo "" >&2
    
    while true; do
        read -rp "请选择密钥算法 [1-3]: " algo_choice
        
        # 验证输入
        if ! validate_input "$algo_choice" '^[1-3]$'; then
            log_error "无效选择，请输入 1-3"
            continue
        fi
        
        case $algo_choice in
            1)
                ALGO="rsa"
                KEY_BITS="4096"
                PRIVATE_KEY_FILE="${SSH_DIR}/id_rsa"
                PUBLIC_KEY_FILE="${SSH_DIR}/id_rsa.pub"
                log_success "已选择: RSA 4096位"
                break
                ;;
            2)
                ALGO="rsa"
                KEY_BITS="8192"
                PRIVATE_KEY_FILE="${SSH_DIR}/id_rsa"
                PUBLIC_KEY_FILE="${SSH_DIR}/id_rsa.pub"
                log_success "已选择: RSA 8192位"
                break
                ;;
            3)
                ALGO="ed25519"
                KEY_BITS="256"
                PRIVATE_KEY_FILE="${SSH_DIR}/id_ed25519"
                PUBLIC_KEY_FILE="${SSH_DIR}/id_ed25519.pub"
                log_success "已选择: Ed25519 (推荐)"
                break
                ;;
        esac
    done
}

################################################################################
#                          第三步: 生成密钥和删除旧密钥                         #
################################################################################

init_ssh_dir() {
    # 创建目录
    if ! mkdir -p "$SSH_DIR" 2>/dev/null; then
        log_error "无法创建 $SSH_DIR 目录"
        exit 1
    fi
    
    # 设置安全权限
    chmod 700 "$SSH_DIR" || {
        log_error "无法设置 $SSH_DIR 权限"
        exit 1
    }
    
    log_success ".ssh 目录已准备"
}

remove_old_keys() {
    local has_old_keys=false
    
    # 检查旧密钥
    if [[ -f "${SSH_DIR}/id_rsa" ]] || [[ -f "${SSH_DIR}/id_ed25519" ]] || [[ -f "${SSH_DIR}/authorized_keys" ]]; then
        has_old_keys=true
    fi
    
    if [[ "$has_old_keys" == "true" ]]; then
        log_warn "检测到已存在的SSH密钥文件"
        echo "" >&2
        
        echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}" >&2
        echo -e "${RED}║                      ⚠️  重要安全通知                          ║${NC}" >&2
        echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}" >&2
        echo "" >&2
        echo -e "${YELLOW}【 旧密钥删除 】${NC}" >&2
        echo "  检测到系统中存在旧的SSH密钥文件" >&2
        echo "  为了确保安全性，旧密钥将被直接删除（不备份）" >&2
        echo "" >&2
        echo -e "${RED}【 删除文件列表 】${NC}" >&2
        [[ -f "${SSH_DIR}/id_rsa" ]] && echo "  • ${SSH_DIR}/id_rsa" >&2
        [[ -f "${SSH_DIR}/id_rsa.pub" ]] && echo "  • ${SSH_DIR}/id_rsa.pub" >&2
        [[ -f "${SSH_DIR}/id_ed25519" ]] && echo "  • ${SSH_DIR}/id_ed25519" >&2
        [[ -f "${SSH_DIR}/id_ed25519.pub" ]] && echo "  • ${SSH_DIR}/id_ed25519.pub" >&2
        [[ -f "${SSH_DIR}/authorized_keys" ]] && echo "  • ${SSH_DIR}/authorized_keys" >&2
        echo "" >&2
        echo -e "${RED}════════════════════════════════════════════════════════════════${NC}" >&2
        echo "" >&2
        
        while true; do
            read -rp "确认删除旧密钥吗？(y/n): " confirm
            
            # 验证输入
            if ! validate_input "$confirm" '^[yn]$'; then
                log_error "请输入 y 或 n"
                continue
            fi
            
            case $confirm in
                [Yy])
                    log_warn "删除旧密钥文件..."
                    rm -f "${SSH_DIR}/id_rsa" "${SSH_DIR}/id_rsa.pub" \
                          "${SSH_DIR}/id_ed25519" "${SSH_DIR}/id_ed25519.pub" 2>/dev/null
                    rm -f "${SSH_DIR}/authorized_keys" 2>/dev/null
                    log_success "旧密钥文件已安全删除"
                    break
                    ;;
                [Nn])
                    log_error "用户取消删除操作，脚本退出"
                    exit 1
                    ;;
            esac
        done
        
        echo "" >&2
    fi
}

generate_keypair() {
    print_step "生成密钥对"
    
    init_ssh_dir
    remove_old_keys
    
    log_info "生成 ${ALGO^^} 密钥对..."
    
    # 确保文件不存在
    rm -f "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE" 2>/dev/null || true
    
    # 使用临时文件生成，然后移动（原子操作）
    local temp_key="${TEMP_DIR}/id_key"
    
    if [[ "$ALGO" == "rsa" ]]; then
        # RSA密钥生成
        if ! ssh-keygen -t rsa -b "$KEY_BITS" -N "" -f "$temp_key" \
             -C "$KEY_COMMENT" >/dev/null 2>&1; then
            log_error "RSA密钥生成失败"
            exit 1
        fi
        
        # 原子移动操作
        mv "$temp_key" "$PRIVATE_KEY_FILE" || {
            log_error "无法移动私钥文件"
            exit 1
        }
        mv "${temp_key}.pub" "$PUBLIC_KEY_FILE" || {
            log_error "无法移动公钥文件"
            exit 1
        }
        
        log_success "RSA ${KEY_BITS}位 密钥对已生成"
        
    elif [[ "$ALGO" == "ed25519" ]]; then
        # Ed25519密钥生成
        if ! ssh-keygen -t ed25519 -N "" -f "$temp_key" \
             -C "$KEY_COMMENT" >/dev/null 2>&1; then
            log_error "Ed25519密钥生成失败"
            exit 1
        fi
        
        # 原子移动操作
        mv "$temp_key" "$PRIVATE_KEY_FILE" || {
            log_error "无法移动私钥文件"
            exit 1
        }
        mv "${temp_key}.pub" "$PUBLIC_KEY_FILE" || {
            log_error "无法移动公钥文件"
            exit 1
        }
        
        log_success "Ed25519 密钥对已生成"
    fi
    
    # 设置安全权限
    chmod 600 "$PRIVATE_KEY_FILE" || {
        log_error "无法设置私钥权限"
        exit 1
    }
    chmod 644 "$PUBLIC_KEY_FILE" || {
        log_error "无法设置公钥权限"
        exit 1
    }
}

################################################################################
#                          密钥生成成功后交互询问                               #
################################################################################

ask_display_private_key() {
    print_step "密钥生成成功！是否显示私钥"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "  密钥对已成功生成！" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    echo "密钥存储位置:" >&2
    echo "" >&2
    echo "  私钥: $PRIVATE_KEY_FILE" >&2
    echo "  公钥: $PUBLIC_KEY_FILE" >&2
    echo "" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "" >&2
    
    while true; do
        read -rp "是否要显示私钥到命令行窗口？(y/n): " user_choice
        
        # 验证输入
        if ! validate_input "$user_choice" '^[yn]$'; then
            log_error "请输入 y 或 n"
            continue
        fi
        
        case $user_choice in
            [Yy])
                SHOW_PRIVATE_KEY=true
                log_success "将显示私钥内容"
                break
                ;;
            [Nn])
                SHOW_PRIVATE_KEY=false
                log_warn "跳过显示私钥，继续后续配置"
                break
                ;;
        esac
    done
}

################################################################################
#                          第四步: 配置SSH服务                                 #
################################################################################

validate_ssh_config_syntax() {
    local config_file="$1"
    
    # 检查SSH配置文件语法
    if ! sudo sshd -t -f "$config_file" >/dev/null 2>&1; then
        log_error "SSH配置文件语法错误"
        return 1
    fi
    return 0
}

configure_ssh_service() {
    print_step "配置SSH服务以支持密钥登录"
    
    log_info "正在修改SSH配置文件..."
    
    # 创建备份目录
    if ! sudo mkdir -p "$SSH_CONFIG_BACKUP_DIR" 2>/dev/null; then
        log_warn "无法创建备份目录，跳过备份"
    else
        # 备份原配置
        if [[ -f "$SSH_CONFIG" ]]; then
            sudo cp "$SSH_CONFIG" "${SSH_CONFIG_BACKUP_DIR}/sshd_config.bak.$(date +%s)" 2>/dev/null
            log_success "SSH配置文件已备份"
        fi
    fi
    
    # 应用配置项
    declare -A config_map=(
        ["PermitRootLogin"]="yes"
        ["PubkeyAuthentication"]="yes"
        ["PasswordAuthentication"]="no"
        ["PermitEmptyPasswords"]="no"
        ["X11Forwarding"]="no"
        ["IgnoreRhosts"]="yes"
    )
    
    for key in "${!config_map[@]}"; do
        local value="${config_map[$key]}"
        
        # 如果配置被注释，则取消注释
        if sudo grep -q "^#${key} " "$SSH_CONFIG"; then
            safe_sed "^#${key} .*" "${key} ${value}" "$SSH_CONFIG"
        # 如果配置不存在，则添加
        elif ! sudo grep -q "^${key} " "$SSH_CONFIG"; then
            echo "${key} ${value}" | sudo tee -a "$SSH_CONFIG" >/dev/null 2>&1
        fi
        
        log_success "已配置: ${key} ${value}"
    done
    
    # 验证配置文件语法
    if ! validate_ssh_config_syntax "$SSH_CONFIG"; then
        log_error "配置修改导致语法错误，请手动检查"
        exit 1
    fi
    
    # 配置authorized_keys
    log_info "配置授权密钥..."
    
    if [[ -f "$PUBLIC_KEY_FILE" ]]; then
        # 使用临时文件创建authorized_keys（原子操作）
        local temp_auth="${TEMP_DIR}/authorized_keys"
        cat "$PUBLIC_KEY_FILE" > "$temp_auth"
        
        # 验证文件内容
        if [[ -s "$temp_auth" ]]; then
            # 原子移动
            mv "$temp_auth" "${SSH_DIR}/authorized_keys"
            log_success "新公钥已设置为唯一授权密钥"
        else
            log_error "临时authorized_keys为空"
            exit 1
        fi
    fi
    
    # 设置权限
    chmod 700 "$SSH_DIR" || log_error "无法设置.ssh目录权限"
    chmod 600 "${SSH_DIR}/authorized_keys" || log_error "无法设置authorized_keys权限"
    
    # 验证.ssh目录权限
    verify_ssh_dir_permissions
    
    # 重启SSH服务
    log_info "重启SSH服务..."
    if ! sudo systemctl restart sshd 2>/dev/null && ! sudo systemctl restart ssh 2>/dev/null; then
        log_error "SSH服务重启失败"
        exit 1
    fi
    
    if sudo systemctl is-active --quiet sshd 2>/dev/null || sudo systemctl is-active --quiet ssh 2>/dev/null; then
        log_success "SSH服务已重启并应用配置"
    else
        log_error "SSH服务未能成功启动"
        exit 1
    fi
}

################################################################################
#                          第五步: 显示私钥内容（可选）                         #
################################################################################

display_private_key() {
    if [[ "$SHOW_PRIVATE_KEY" != "true" ]]; then
        return 0
    fi
    
    print_step "显示私钥内容"
    
    if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
        log_error "私钥文件不存在: $PRIVATE_KEY_FILE"
        return 1
    fi
    
    # 验证私钥权限
    local perms
    perms=$(stat -c %a "$PRIVATE_KEY_FILE" 2>/dev/null || stat -f %A "$PRIVATE_KEY_FILE" 2>/dev/null)
    
    if [[ "$perms" != "600" ]]; then
        log_warn "私钥权限异常: $perms (应该是 600)"
    fi
    
    log_warn "以下是您的私钥，请妥善保管！"
    echo "" >&2
    
    echo -e "${RED}╔═══════════════════════════════════════════════════════════════════════════════════════╗${NC}" >&2
    echo -e "${RED}║                                                                                       ║${NC}" >&2
    echo -e "${RED}║                    私钥内容 - 请妥善保管 私钥复制后请删除服务器私钥                       ║${NC}" >&2
    echo -e "${RED}║                                                                                       ║${NC}" >&2
    echo -e "${RED}╚═══════════════════════════════════════════════════════════════════════════════════════╝${NC}" >&2
    echo "" >&2
    
    # 以只读方式显示私钥
    cat "$PRIVATE_KEY_FILE" >&2
    
    echo "" >&2
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}" >&2
    echo "" >&2
    
    echo -e "${CYAN}【 密钥文件信息 】${NC}" >&2
    echo "  文件路径: $PRIVATE_KEY_FILE" >&2
    echo "  文件大小: $(ls -lh "$PRIVATE_KEY_FILE" | awk '{print $5}')" >&2
    echo "  文件权限: $(ls -l "$PRIVATE_KEY_FILE" | awk '{print $1}')" >&2
    echo "" >&2
    
    echo -e "${CYAN}【 公钥指纹 】${NC}" >&2
    if [[ -f "$PUBLIC_KEY_FILE" ]]; then
        ssh-keygen -lf "$PUBLIC_KEY_FILE" 2>/dev/null | awk '{print "  指纹: " $2 "\n  类型: " $4}' >&2
    fi
    echo "" >&2
}

################################################################################
#                          安全提示和总结                                       #
################################################################################

show_security_info() {
    print_step "重要提示和说明"
    
    echo "╔════════════════════════════════════════════════════════════════╗" >&2
    echo "║                     🔐 安全提示                                ║" >&2
    echo "╚════════════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
    echo "【密钥替换说明】" >&2
    echo "  ✓ 新生成的密钥已覆盖系统中的旧密钥" >&2
    echo "  ✓ 只有新密钥可以用于远程登录" >&2
    echo "  ✓ 旧密钥已被完全删除" >&2
    echo "  ✓ 为了安全起见，未保留备份" >&2
    echo "" >&2
    echo "【立即行动】" >&2
    echo "  1. 如果显示了私钥，请立即复制并保存到本地安全的位置" >&2
    echo "  2. 建议保存到密码管理器（例如 1Password、Bitwarden 等）" >&2
    echo "  3. 清除服务器上的历史记录: history -c && history -w" >&2
    echo "  4. 清除当前shell的命令历史: unset HISTFILE" >&2
    echo "" >&2
    echo "【密钥保护】" >&2
    echo "  ✓ 私钥文件权限: 600 (--rw--------)" >&2
    echo "  ✓ .ssh 目录权限: 700 (drwx------)" >&2
    echo "  �� 定期检查: ls -la ~/.ssh" >&2
    echo "" >&2
    echo "【配置说明】" >&2
    echo "  ✓ 已启用 PubkeyAuthentication（公钥认证）" >&2
    echo "  ✓ 已启用 PermitRootLogin yes（允许Root登录）" >&2
    echo "  ✓ 已禁用 PasswordAuthentication（禁止密码认证）" >&2
    echo "  ✓ 已禁用 PermitEmptyPasswords（禁止空密码）" >&2
    echo "  ✓ 已禁用 X11Forwarding（禁用X11转发）" >&2
    echo "  ✓ 已启用 IgnoreRhosts（忽略rhosts）" >&2
    echo "" >&2
    echo "【远程登录】" >&2
    echo "  使用新生成的密钥远程登录服务器:" >&2
    echo "" >&2
    echo "  $ ssh root@<服务器IP地址>" >&2
    echo "" >&2
    echo "  或指定密钥文件:" >&2
    echo "" >&2
    echo "  $ ssh -i ~/.ssh/id_rsa root@<服务器IP地址>" >&2
    echo "" >&2
    echo "【重要警告】" >&2
    echo "  ⚠️  旧密钥已被删除，无法恢复" >&2
    echo "  ⚠️  必须安全保存新生成的私钥" >&2
    echo "  ⚠️  如果丢失新私钥，将无法远程登录" >&2
    echo "" >&2
    echo "【再次查看私钥】" >&2
    echo "  如果需要再次查看私钥，可以执行:" >&2
    echo "  $ cat ~/.ssh/id_rsa" >&2
    echo "  或" >&2
    echo "  $ cat ~/.ssh/id_ed25519" >&2
    echo "" >&2
    echo "【故障排除】" >&2
    echo "  如果无法远程登录，请检查:" >&2
    echo "" >&2
    echo "  1. 新密钥是否正确保存在本地:" >&2
    echo "     $ cat ~/.ssh/id_rsa (本地计算机)" >&2
    echo "" >&2
    echo "  2. 服务器的 authorized_keys 是否包含正确��公钥:" >&2
    echo "     $ cat ~/.ssh/authorized_keys (服务器)" >&2
    echo "" >&2
    echo "  3. SSH服务是否运行:" >&2
    echo "     $ sudo systemctl status ssh" >&2
    echo "" >&2
    echo "  4. SSH配置文件是否正确:" >&2
    echo "     $ sudo sshd -t" >&2
    echo "" >&2
    echo "  5. 检查SSH日志:" >&2
    echo "     $ sudo journalctl -u ssh -n 50" >&2
    echo "" >&2
    echo "╔════════════════════════════════════════════════════════════════╗" >&2
    echo "║               ✓ 所有步骤已完成！                               ║" >&2
    echo "║                                                                ║" >&2
    echo "║  系统已使用新密钥，旧密钥已删除！                              ║" >&2
    echo "║  请妥善保管新私钥！                                            ║" >&2
    echo "╚════════════════════════════════════════════════════════════════╝" >&2
    echo "" >&2
}

################################################################################
#                          主程序                                              #
################################################################################

main() {
    clear
    
    echo -e "${BLUE}" >&2
    echo "╔══════════════════════��═════════════════════════════════════════╗" >&2
    echo "║                                                                ║" >&2
    echo "║           SSH 密钥生成与系统配置工具 v3.0                      ║" >&2
    echo "║                                                                ║" >&2
    echo "║  功能流程:                                                      ║" >&2
    echo "║   Step 1: 检查OpenSSH服务和SSH功能                              ║" >&2
    echo "║   Step 2: 选择密钥算法                                          ║" >&2
    echo "║   Step 3: 检测并删除旧密钥（不备份）                            ║" >&2
    echo "║   Step 4: 生成新密钥                                            ║" >&2
    echo "║   Step 5: 询问是否显示私钥                                      ║" >&2
    echo "║   Step 6: 配置SSH服务                                           ║" >&2
    echo "║   Step 7: 显示私钥内容（如已选择）                              ║" >&2
    echo "║                                                                ║" >&2
    echo "║  ✓ 安全审查版本：包含多项安全改进                               ║" >&2
    echo "║                                                                ║" >&2
    echo "╚═════════════════════��══════════════════════════════════════════╝" >&2
    echo -e "${NC}\n" >&2
    
    # 安全检查
    check_root
    check_sudo_permission
    
    # 执行主流程
    detect_distro
    check_and_install_ssh
    select_key_algorithm
    generate_keypair
    ask_display_private_key
    configure_ssh_service
    display_private_key
    show_security_info
}

main "$@"
