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
#  版本: v2.7 (修复 here-document 语法错误)                                     #
#  日期: 2025-04-07                                                            #
#                                                                              #
################################################################################

set -e

# 颜色定义
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
SSH_DIR="$HOME/.ssh"
SSH_CONFIG="/etc/ssh/sshd_config"
DISTRO=""
ALGO=""
KEY_BITS=""
SHOW_PRIVATE_KEY=false
PRIVATE_KEY_FILE=""
PUBLIC_KEY_FILE=""

################################################################################
#                          输出函数                                             #
################################################################################

log_info() {
    echo -e "${CYAN}[ℹ]${NC} $@"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $@"
}

log_warn() {
    echo -e "${YELLOW}[⚠]${NC} $@"
}

log_error() {
    echo -e "${RED}[✗]${NC} $@"
}

print_step() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}● Step: $@${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

################################################################################
#                          第一步: 检查和安装OpenSSH服务                        #
################################################################################

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
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
}

install_ssh_client() {
    log_info "正在安装 SSH 客户端..."
    
    case "$DISTRO" in
        debian|ubuntu)
            sudo apt-get update -qq >/dev/null 2>&1
            sudo apt-get install -y openssh-client >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            sudo yum install -y openssh-clients >/dev/null 2>&1
            ;;
        alpine)
            sudo apk add --no-cache openssh-client >/dev/null 2>&1
            ;;
        arch)
            sudo pacman -S --noconfirm openssh >/dev/null 2>&1
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
            sudo apt-get update -qq >/dev/null 2>&1
            sudo apt-get install -y openssh-server >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky|almalinux)
            sudo yum install -y openssh-server >/dev/null 2>&1
            ;;
        alpine)
            sudo apk add --no-cache openssh >/dev/null 2>&1
            ;;
        arch)
            sudo pacman -S --noconfirm openssh >/dev/null 2>&1
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
        log_success "SSH 服务已��动并设置开机自启"
    else
        log_error "SSH 服务启动失败"
        exit 1
    fi
}

################################################################################
#                          第二步: 密钥算法选择交互                             #
################################################################################

select_key_algorithm() {
    print_step "选择密钥算法"
    
    echo "┌──────────────┬─────────────┬──────────┬─────────────────────────┐"
    echo "│ 选项         │ 算法        │ 密钥大小 │ 特点                    │"
    echo "├──────────────┼─────────────┼──────────┼─────────────────────────┤"
    echo "│ 1            │ RSA 4096    │ 4096位   │ 兼容性好，应用广泛      │"
    echo "│ 2            │ RSA 8192    │ 8192位   │ 超高安全性，生成较慢    │"
    echo "│ 3            │ Ed25519     │ 256bit   │ ★推荐★ 快速高效安全    │"
    echo "└──────────────┴─────────────┴──────────┴─────────────────────────┘"
    echo ""
    echo "算法说明:"
    echo "  • RSA 4096: 广泛兼容，适合大多数场景"
    echo "  • RSA 8192: 最高安全级别，推荐用于政府/金融等敏感领域"
    echo "  • Ed25519:  现代算法，运算速度快，安全性强（★★★推荐★★★）"
    echo ""
    
    while true; do
        read -p "请选择密钥算法 [1-3]: " algo_choice
        
        case $algo_choice in
            1)
                ALGO="rsa"
                KEY_BITS="4096"
                PRIVATE_KEY_FILE="$SSH_DIR/id_rsa"
                PUBLIC_KEY_FILE="$SSH_DIR/id_rsa.pub"
                log_success "已选择: RSA 4096位"
                break
                ;;
            2)
                ALGO="rsa"
                KEY_BITS="8192"
                PRIVATE_KEY_FILE="$SSH_DIR/id_rsa"
                PUBLIC_KEY_FILE="$SSH_DIR/id_rsa.pub"
                log_success "已选择: RSA 8192位"
                break
                ;;
            3)
                ALGO="ed25519"
                KEY_BITS="256"
                PRIVATE_KEY_FILE="$SSH_DIR/id_ed25519"
                PUBLIC_KEY_FILE="$SSH_DIR/id_ed25519.pub"
                log_success "已选择: Ed25519 (推荐)"
                break
                ;;
            *)
                log_error "无效选择，请输入 1-3"
                ;;
        esac
    done
}

################################################################################
#                          第三步: 生成密钥和删除旧密钥                         #
################################################################################

init_ssh_dir() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
}

remove_old_keys() {
    local has_old_keys=false
    
    if [[ -f "$SSH_DIR/id_rsa" ]] || [[ -f "$SSH_DIR/id_ed25519" ]] || [[ -f "$SSH_DIR/authorized_keys" ]]; then
        has_old_keys=true
    fi
    
    if [[ "$has_old_keys" == "true" ]]; then
        log_warn "检测到已存在的SSH密钥文件"
        echo ""
        
        echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║                      ⚠️  重要安全通知                          ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}【 旧密钥删除 】${NC}"
        echo "  检测到系统中存在旧的SSH密钥文件"
        echo "  为了确保安全性，旧密钥将被直接删除（不备份）"
        echo ""
        echo -e "${RED}【 删除文件列表 】${NC}"
        [[ -f "$SSH_DIR/id_rsa" ]] && echo "  • $SSH_DIR/id_rsa"
        [[ -f "$SSH_DIR/id_rsa.pub" ]] && echo "  • $SSH_DIR/id_rsa.pub"
        [[ -f "$SSH_DIR/id_ed25519" ]] && echo "  • $SSH_DIR/id_ed25519"
        [[ -f "$SSH_DIR/id_ed25519.pub" ]] && echo "  • $SSH_DIR/id_ed25519.pub"
        [[ -f "$SSH_DIR/authorized_keys" ]] && echo "  • $SSH_DIR/authorized_keys"
        echo ""
        echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        while true; do
            read -p "确认删除旧密钥吗？(y/n): " confirm
            case $confirm in
                [Yy])
                    log_warn "删除旧密钥文件..."
                    rm -f "$SSH_DIR/id_rsa" "$SSH_DIR/id_rsa.pub" "$SSH_DIR/id_ed25519" "$SSH_DIR/id_ed25519.pub" 2>/dev/null
                    rm -f "$SSH_DIR/authorized_keys" 2>/dev/null
                    log_success "旧密钥文件已删除"
                    break
                    ;;
                [Nn])
                    log_error "用户取消删除操作，脚本退出"
                    exit 1
                    ;;
                *)
                    log_error "请输入 y 或 n"
                    ;;
            esac
        done
        
        echo ""
    fi
}

generate_keypair() {
    print_step "生成密钥对"
    
    init_ssh_dir
    remove_old_keys
    
    log_info "生成 ${ALGO^^} 密钥对..."
    
    rm -f "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE" 2>/dev/null || true
    
    if [[ "$ALGO" == "rsa" ]]; then
        ssh-keygen -t rsa -b "$KEY_BITS" -N "" -f "$PRIVATE_KEY_FILE" -C "root@$(hostname)" 2>&1
        chmod 600 "$PRIVATE_KEY_FILE"
        chmod 644 "$PUBLIC_KEY_FILE"
        log_success "RSA ${KEY_BITS}位 密钥对已生成"
    elif [[ "$ALGO" == "ed25519" ]]; then
        ssh-keygen -t ed25519 -N "" -f "$PRIVATE_KEY_FILE" -C "root@$(hostname)" 2>&1
        chmod 600 "$PRIVATE_KEY_FILE"
        chmod 644 "$PUBLIC_KEY_FILE"
        log_success "Ed25519 密钥对已生成"
    fi
}

################################################################################
#                          密钥生成成功后交互询问                               #
################################################################################

ask_display_private_key() {
    print_step "密钥生成成功！是否显示私钥"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  密钥对已成功生成！"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "密钥存储位置:"
    echo ""
    echo "  私钥: $PRIVATE_KEY_FILE"
    echo "  公钥: $PUBLIC_KEY_FILE"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    while true; do
        read -p "是否要显示私钥到命令行窗口？(y/n): " user_choice
        
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
            *)
                log_error "请输入 y 或 n"
                ;;
        esac
    done
}

################################################################################
#                          第四步: 配置SSH服务                                 #
################################################################################

configure_ssh_service() {
    print_step "配置SSH服务以支持密钥登录"
    
    log_info "正在修改SSH配置文件..."
    
    if [[ -f "$SSH_CONFIG" ]]; then
        sudo cp "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%s)" 2>/dev/null
        log_success "SSH配置文件已备份"
    fi
    
    declare -A config_map=(
        ["PermitRootLogin"]="yes"
        ["PubkeyAuthentication"]="yes"
        ["PasswordAuthentication"]="no"
        ["PermitEmptyPasswords"]="no"
    )
    
    for key in "${!config_map[@]}"; do
        value="${config_map[$key]}"
        
        if sudo grep -q "^#${key} " "$SSH_CONFIG"; then
            sudo sed -i "s/^#${key} .*/${key} ${value}/" "$SSH_CONFIG"
        elif ! sudo grep -q "^${key} " "$SSH_CONFIG"; then
            echo "${key} ${value}" | sudo tee -a "$SSH_CONFIG" >/dev/null 2>&1
        fi
        
        log_success "已配置: ${key} ${value}"
    done
    
    log_info "配置授权密钥..."
    
    if [[ -f "$PUBLIC_KEY_FILE" ]]; then
        cat "$PUBLIC_KEY_FILE" > "$SSH_DIR/authorized_keys"
        log_success "新公钥已设置为唯一授权密钥"
    fi
    
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    
    log_info "重启SSH服务..."
    sudo systemctl restart sshd 2>/dev/null || sudo systemctl restart ssh 2>/dev/null
    
    if sudo systemctl is-active --quiet sshd 2>/dev/null || sudo systemctl is-active --quiet ssh 2>/dev/null; then
        log_success "SSH服务已重启并应用配置"
    else
        log_error "SSH服务重启失败，请手动检查配置"
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
    
    log_warn "以下是您的私钥，请妥善保管！"
    echo ""
    
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║                    私钥内容 - 请妥善保管                        ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    cat "$PRIVATE_KEY_FILE"
    
    echo ""
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    echo -e "${CYAN}【 密钥文件信息 】${NC}"
    echo "  文件路径: $PRIVATE_KEY_FILE"
    echo "  文件大小: $(ls -lh $PRIVATE_KEY_FILE | awk '{print $5}')"
    echo "  文件权限: $(ls -l $PRIVATE_KEY_FILE | awk '{print $1}')"
    echo ""
    
    echo -e "${CYAN}【 公钥指纹 】${NC}"
    if [[ -f "$PUBLIC_KEY_FILE" ]]; then
        ssh-keygen -lf "$PUBLIC_KEY_FILE" 2>/dev/null | awk '{print "  指纹: " $2 "\n  类型: " $4}'
    fi
    echo ""
}

################################################################################
#                          安全提示和总结                                       #
################################################################################

show_security_info() {
    print_step "重要提示和说明"
    
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                     🔐 安全提示                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "【密钥替换说明】"
    echo "  ✓ 新生成的密钥已覆盖系统中的旧密钥"
    echo "  ✓ 只有新密钥可以用于远程登录"
    echo "  ✓ 旧密钥已��完全删除"
    echo "  ✓ 为了安全起见，未保留备份"
    echo ""
    echo "【立即行动】"
    echo "  1. 如果显示了私钥，请立即复制并保存到本地安全的位置"
    echo "  2. 建议保存到密码管理器（例如 1Password、Bitwarden 等）"
    echo "  3. 清除服务器上的历史记录: history -c"
    echo ""
    echo "【密钥保护】"
    echo "  ✓ 私钥文件权限: 600 (--rw--------)"
    echo "  ✓ .ssh 目录权限: 700 (drwx------)"
    echo "  ✓ 定期检查: ls -la ~/.ssh"
    echo ""
    echo "【配置说明】"
    echo "  ✓ 已启用 PubkeyAuthentication（公钥认证）"
    echo "  ✓ 已启用 PermitRootLogin yes（允许Root登录）"
    echo "  ✓ 已禁用 PasswordAuthentication（禁止密码认证）"
    echo "  ✓ 已禁用 PermitEmptyPasswords（禁止空密码）"
    echo ""
    echo "【远程登录】"
    echo "  使用新生成的密钥远程登录服务器:"
    echo ""
    echo "  $ ssh root@<服务器IP地址>"
    echo ""
    echo "  或指定密钥文件:"
    echo ""
    echo "  $ ssh -i ~/.ssh/id_rsa root@<服务器IP地址>"
    echo ""
    echo "【重要警告】"
    echo "  ⚠️  旧密钥已被删除，无法恢复"
    echo "  ⚠️  必须安全保存新生成的私钥"
    echo "  ⚠️  如果丢失新私钥，将无法远程登录"
    echo ""
    echo "【再次查看私钥】"
    echo "  如果需要再次查看私钥，可以执行:"
    echo "  $ cat ~/.ssh/id_rsa"
    echo "  或"
    echo "  $ cat ~/.ssh/id_ed25519"
    echo ""
    echo "【故障排除】"
    echo "  如果无法远程登录，请检查:"
    echo ""
    echo "  1. 新密钥是否正确保存在本地:"
    echo "     $ cat ~/.ssh/id_rsa (本地计算机)"
    echo ""
    echo "  2. 服务器的 authorized_keys 是否包含正确的公钥:"
    echo "     $ cat ~/.ssh/authorized_keys (服务器)"
    echo ""
    echo "  3. SSH服务是否运行:"
    echo "     $ sudo systemctl status ssh"
    echo ""
    echo "  4. SSH配置文件是否正确:"
    echo "     $ sudo sshd -t"
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║               ✓ 所有步骤已完成！                               ║"
    echo "║                                                                ║"
    echo "║  系统已使用新密钥，旧密钥已删除！                              ║"
    echo "║  请妥善保管新私钥！                                            ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""
}

################################################################################
#                          主程序                                              #
################################################################################

main() {
    clear
    
    echo -e "${BLUE}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║           SSH 密钥生成与系统配置工具 v2.7                      ║"
    echo "║                                                                ║"
    echo "║  功能流程:                                                      ║"
    echo "║   Step 1: 检查OpenSSH服务和SSH功能                              ║"
    echo "║   Step 2: 选择密钥算法                                          ║"
    echo "║   Step 3: 检测并删除旧密钥（不备份）                            ║"
    echo "║   Step 4: 生成新密钥                                            ║"
    echo "║   Step 5: 询问是否显示私钥                                      ║"
    echo "║   Step 6: 配置SSH服务                                           ║"
    echo "║   Step 7: 显示私钥内容（如已选择）                              ║"
    echo "║                                                                ║"
    echo "║  ✓ 最大安全：旧密钥已删除，不保留任何备份！                     ║"
    echo "║                                                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}\n"
    
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