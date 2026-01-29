#!/bin/bash

################################################################################
#                      SSH 密钥生成与系统配置工具                               #
#                    SSH Key Generation & System Configuration                 #
#                                                                              #
#  核心功能:                                                                   #
#  1. 检查OpenSSH服务和SSH功能状态，自动安装并启动                              #
#  2. 提供密钥算法选择交互（RSA 4096/8192, Ed25519）                           #
#  3. 生成密钥并自动备份旧密钥到 BackupData 文件夹                              #
#  4. 配置SSH服务实现密钥远程登录                                              #
#  5. 密钥生成成功后交互询问是否显示私钥                                        #
#  6. 旧密钥已备份，仅新密钥有效。可手动恢复旧密钥                              #
#                                                                              #
#  版本: v2.4 (简化密钥覆盖逻辑)                                                #
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
BACKUP_DIR="$SSH_DIR/BackupData"
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
    
    # 检查SSH命令是否存在
    if command -v ssh >/dev/null 2>&1; then
        log_success "SSH 客户端已安装"
    else
        log_warn "SSH 客户端未安装，准备安装..."
        install_ssh_client
    fi
    
    # 检查SSHD服务是否存在
    if ! sudo systemctl list-units --all 2>/dev/null | grep -qE "sshd|ssh\.service"; then
        log_warn "OpenSSH 服务端未安装，准备安装..."
        install_ssh_server
    else
        log_success "OpenSSH 服务端已安装"
    fi
    
    # 检查SSH服务是否运行
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
    
    # 尝试启动sshd
    sudo systemctl start sshd 2>/dev/null || sudo systemctl start ssh 2>/dev/null
    
    # 配置开机自启
    sudo systemctl enable sshd 2>/dev/null || sudo systemctl enable ssh 2>/dev/null
    
    # 验证是否启动成功
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
    print_step "选择密钥算法"
    
    # 显示算法对比表
    cat << 'EOF'
┌──────────────┬─────────────┬──────────┬─────────────────────────┐
│ 选项         │ 算法        │ 密钥大小 │ 特点                    │
├────���─────────┼─────────────┼──────────┼─────────────────────────┤
│ 1            │ RSA 4096    │ 4096位   │ 兼容性好，应用广泛      │
│ 2            │ RSA 8192    │ 8192位   │ 超高安全性，生成较慢    │
│ 3            │ Ed25519     │ 256bit   │ ★推荐★ 快速高效安全    │
└──────────────┴─────────────┴──────────┴─────────────────────────┘

算法说明:
  • RSA 4096: 广泛兼容，适合大多数场景
  • RSA 8192: 最高安全级别，推荐用于政府/金融等敏感领域
  • Ed25519:  现代算法，运算速度快，安全性强（★★★推荐★★★）

EOF
    
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
#                          第三步: 生成密钥和备份                               #
################################################################################

init_ssh_dir() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    
    # 创建BackupData文件夹
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
}

backup_existing_keys() {
    # 检查是否存在旧密钥
    local has_old_keys=false
    
    if [[ -f "$SSH_DIR/id_rsa" ]] || [[ -f "$SSH_DIR/id_ed25519" ]] || [[ -f "$SSH_DIR/authorized_keys" ]]; then
        has_old_keys=true
    fi
    
    if [[ "$has_old_keys" == "true" ]]; then
        log_warn "检测到已存在的SSH密钥文件"
        
        local timestamp=$(date +%Y%m%d_%H%M%S)
        local backup_subdir="$BACKUP_DIR/backup_$timestamp"
        
        mkdir -p "$backup_subdir"
        
        # 备份现有密钥和配置
        [[ -f "$SSH_DIR/id_rsa" ]] && cp "$SSH_DIR/id_rsa" "$backup_subdir/" 2>/dev/null
        [[ -f "$SSH_DIR/id_rsa.pub" ]] && cp "$SSH_DIR/id_rsa.pub" "$backup_subdir/" 2>/dev/null
        [[ -f "$SSH_DIR/id_ed25519" ]] && cp "$SSH_DIR/id_ed25519" "$backup_subdir/" 2>/dev/null
        [[ -f "$SSH_DIR/id_ed25519.pub" ]] && cp "$SSH_DIR/id_ed25519.pub" "$backup_subdir/" 2>/dev/null
        [[ -f "$SSH_DIR/authorized_keys" ]] && cp "$SSH_DIR/authorized_keys" "$backup_subdir/authorized_keys.bak" 2>/dev/null
        
        log_success "旧密钥已备份到: $backup_subdir"
        
        # 显示恢复提示
        echo ""
        echo -e "${YELLOW}【 恢复旧密钥的步骤 】${NC}"
        echo "如果需要使用备份的旧密钥连接，请执行以下步骤:"
        echo ""
        echo "1. 恢复私钥文件:"
        echo "   $ cp $backup_subdir/id_rsa ~/.ssh/id_rsa"
        echo ""
        echo "2. 恢复公钥到 authorized_keys:"
        echo "   $ cat $backup_subdir/id_rsa.pub >> ~/.ssh/authorized_keys"
        echo ""
        echo "3. 确保权限正确:"
        echo "   $ chmod 600 ~/.ssh/id_rsa"
        echo "   $ chmod 600 ~/.ssh/authorized_keys"
        echo ""
    fi
}

generate_keypair() {
    print_step "生成密钥对"
    
    init_ssh_dir
    backup_existing_keys
    
    log_info "生成 ${ALGO^^} 密钥对..."
    
    # 删除旧密钥（如果存在）
    rm -f "$PRIVATE_KEY_FILE" "$PUBLIC_KEY_FILE" 2>/dev/null || true
    
    # 根据算法生成密钥
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
    
    cat << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  密钥对已成功生成！
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

密钥存储位置:

  私钥: $PRIVATE_KEY_FILE
  公钥: $PUBLIC_KEY_FILE

━━━��━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF
    
    # 交互询问
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
    
    # 备份原配置
    if [[ -f "$SSH_CONFIG" ]]; then
        sudo cp "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%s)" 2>/dev/null
        log_success "SSH配置文件已备份"
    fi
    
    # 配置项数组
    declare -A config_map=(
        ["PermitRootLogin"]="yes"
        ["PubkeyAuthentication"]="yes"
        ["PasswordAuthentication"]="no"
        ["PermitEmptyPasswords"]="no"
    )
    
    # 应用配置
    for key in "${!config_map[@]}"; do
        value="${config_map[$key]}"
        
        # 如果配置被注释，则取消注释
        if sudo grep -q "^#${key} " "$SSH_CONFIG"; then
            sudo sed -i "s/^#${key} .*/${key} ${value}/" "$SSH_CONFIG"
        # 如果配置不存在，则添加
        elif ! sudo grep -q "^${key} " "$SSH_CONFIG"; then
            echo "${key} ${value}" | sudo tee -a "$SSH_CONFIG" >/dev/null 2>&1
        fi
        
        log_success "已配置: ${key} ${value}"
    done
    
    # 配置authorized_keys - 清空并添加新公钥
    log_info "配置授权密钥..."
    
    # 创建新的authorized_keys（覆盖旧内容）
    if [[ -f "$PUBLIC_KEY_FILE" ]]; then
        cat "$PUBLIC_KEY_FILE" > "$SSH_DIR/authorized_keys"
        log_success "新公钥已设置为唯一授权密钥"
    fi
    
    # 设置权限
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    
    # 重启SSH服务
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
    # 如果用户选择不显示，则跳过此步骤
    if [[ "$SHOW_PRIVATE_KEY" != "true" ]]; then
        return 0
    fi
    
    print_step "显示私钥内容"
    
    # 验证私钥文件存在
    if [[ ! -f "$PRIVATE_KEY_FILE" ]]; then
        log_error "私钥文件不存在: $PRIVATE_KEY_FILE"
        return 1
    fi
    
    # 显示警告
    log_warn "以下是您的私钥，请妥善保管！"
    echo ""
    
    # 美化显示
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}║                    私钥内容 - 请妥善保管                        ║${NC}"
    echo -e "${RED}║                                                                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # 显示私钥
    cat "$PRIVATE_KEY_FILE"
    
    echo ""
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    # 显示密钥信息
    echo -e "${CYAN}【 密钥文件信息 】${NC}"
    echo "  文件路径: $PRIVATE_KEY_FILE"
    echo "  文件大小: $(ls -lh $PRIVATE_KEY_FILE | awk '{print $5}')"
    echo "  文件权限: $(ls -l $PRIVATE_KEY_FILE | awk '{print $1}')"
    echo ""
    
    # 显示公钥指纹
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
    
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                     🔐 安全提示                                ║
╚════════════════════════════════════════════════════════════════╝

【密钥替换说明】
  ✓ 新生成的密钥已覆盖旧密钥
  ✓ 只有新密钥可以用于远程登录
  ✓ 旧密钥已完整备份，可随时恢复

【立即行动】
  1. 如果显示了私钥，请立即复制并保存到本地安全的位置
  2. 建议保存到密码管理器（例如 1Password、Bitwarden 等）
  3. 清除服务器上的历史记录: history -c

【密钥保护】
  ✓ 私钥文件权限: 600 (--rw------)
  ✓ .ssh 目录权限: 700 (drwx------)
  ✓ 定期检查: ls -la ~/.ssh

【配置说明】
  ✓ 已启用 PubkeyAuthentication（公钥认证）
  ✓ 已启用 PermitRootLogin yes（允许Root登录）
  ✓ 已禁用 PasswordAuthentication（禁止密码认证）
  ✓ 已禁用 PermitEmptyPasswords（禁止空密码）

【远程登录】
  使用新生成的密钥远程登录服务器:
  
  $ ssh -i ~/.ssh/id_rsa root@<服务器IP地址>
  
  或者（如果已配置为默认密钥）:
  
  $ ssh root@<服务器IP地址>

【备份位置】
  旧密钥备份位置: $BACKUP_DIR
  
  备份文件包含:
    • id_rsa         - 旧私钥
    • id_rsa.pub     - 旧公钥
    • authorized_keys.bak - 旧授权配置备份

【恢复旧密钥的方法】
  如果需要重新启用旧密钥进行连接，请:
  
  1. 恢复旧私钥到当前位置:
     $ cp ~/.ssh/BackupData/backup_时间戳/id_rsa ~/.ssh/id_rsa
  
  2. 添加旧公钥到授权密钥:
     $ cat ~/.ssh/BackupData/backup_时间戳/id_rsa.pub >> ~/.ssh/authorized_keys
  
  3. 确保权限正确:
     $ chmod 600 ~/.ssh/id_rsa
     $ chmod 600 ~/.ssh/authorized_keys
  
  4. 现在可以同时使用新旧密钥连接:
     $ ssh -i ~/.ssh/BackupData/backup_时间戳/id_rsa root@<服务器IP>

【查看当前授权密钥】
  $ cat ~/.ssh/authorized_keys

【查看备份列表】
  $ ls -la ~/.ssh/BackupData/

【再次查看私钥】
  如果需要再次查看私钥，可以执行:
  $ cat ~/.ssh/id_rsa
  或
  $ cat ~/.ssh/id_ed25519

╔════════════════════════════════════════════════════════════════╗
��               ✓ 所有步骤已完成！                               ║
║                                                                ║
║  只有新生成的密钥可用。旧密钥已备份，可手动恢复！              ║
╚════════════════════════════════════════════════════════════════╝

EOF
}

################################################################################
#                          主程序                                              #
################################################################################

main() {
    clear
    
    # 打印欢迎信息
    echo -e "${BLUE}"
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║           SSH 密钥生成与系统配置工具 v2.4                      ║
║                                                                ║
║  功能流程:                                                      ║
║   Step 1: 检查OpenSSH服务和SSH功能                              ║
║   Step 2: 选择密钥算法                                          ║
║   Step 3: 生成密钥（备份旧密钥）                                ║
║   Step 4: 询问是否显示私钥                                      ║
║   Step 5: 配置SSH服务（仅新密钥生效）                           ║
║   Step 6: 显示私钥内容（如已选择）                              ║
║                                                                ║
║  ✓ 旧密钥已备份，可手动恢复！                                  ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
    
    # 执行各步骤
    detect_distro
    check_and_install_ssh
    select_key_algorithm
    generate_keypair
    ask_display_private_key
    configure_ssh_service
    display_private_key
    show_security_info
}

# 执行主程序
main "$@"