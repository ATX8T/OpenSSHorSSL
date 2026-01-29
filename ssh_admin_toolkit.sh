#!/bin/bash

################################################################################
#                      SSH 密钥生成与系统配置工具                               #
#                    SSH Key Generation & System Configuration                 #
#                                                                              #
#  核心功能:                                                                   #
#  1. 检查/安装/启动 SSH 服务                                                   #
#  2. 生成不同算法的密钥对（RSA/Ed25519/ECDSA/Ed448）                           #
#  3. 配置系统允许密钥认证 & Root 登录                                          #
#  4. 显示私钥内容供用户保存                                                    #
#                                                                              #
#  版本: v1.0 (精简版)                                                          #
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
SYSTEM_TYPE=""
DISTRO=""

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

print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$@${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

################################################################################
#                          系统检测与初始化                                     #
################################################################################

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO="$ID"
    elif [[ -f /etc/debian_version ]]; then
        DISTRO="debian"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO="redhat"
    else
        log_error "无法识别系统类型"
        return 1
    fi
    return 0
}

check_ssh_service() {
    print_header "Step 1: SSH 服务检查与安装"
    
    # 检查SSH是否安装
    if ! command -v ssh >/dev/null 2>&1; then
        log_warn "SSH未安装，正在安装..."
        install_ssh_service
    else
        log_success "SSH客户端已安装"
    fi
    
    # 检查SSHD是否安装
    if ! sudo systemctl list-units --all 2>/dev/null | grep -q "sshd\|ssh\.service"; then
        log_warn "SSH服务端未安装，正在安装..."
        install_ssh_service
    else
        log_success "SSH服务端已安装"
    fi
    
    # 检查SSH服务是否运行
    if sudo systemctl is-active --quiet ssh || sudo systemctl is-active --quiet sshd; then
        log_success "SSH服务运行中"
    else
        log_warn "SSH服务未运行，正在启动..."
        sudo systemctl start ssh 2>/dev/null || sudo systemctl start sshd 2>/dev/null
        sudo systemctl enable ssh 2>/dev/null || sudo systemctl enable sshd 2>/dev/null
        log_success "SSH服务已启动"
    fi
}

install_ssh_service() {
    case "$DISTRO" in
        debian|ubuntu)
            sudo apt-get update -qq
            sudo apt-get install -y openssh-client openssh-server >/dev/null 2>&1
            ;;
        centos|rhel|fedora|rocky)
            sudo yum install -y openssh-clients openssh-server >/dev/null 2>&1
            ;;
        alpine)
            sudo apk add --no-cache openssh >/dev/null 2>&1
            ;;
        *)
            log_error "不支持的Linux发行版: $DISTRO"
            return 1
            ;;
    esac
    log_success "SSH已安装"
}

init_ssh_dir() {
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
}

################################################################################
#                          密钥生成                                             #
################################################################################

show_algorithm_info() {
    print_header "Step 2: 选择密钥算法"
    
    cat << 'EOF'
密钥算法对比表:

┌────────────────────────────────────────────────────────────────────┐
│ 算法      │ 密钥大小      │ 安全性  │ 兼容性 │ 性能  │ 推荐度      │
├────────────────────────────────────────────────────────────────────┤
│ RSA 4096  │ 4096位       │ ★★★★☆ │ ★★★★★ │ 一般  │ 兼容性最佳  │
│ RSA 8192  │ 8192位       │ ★★★★★ │ ★★★★☆ │ 较慢  │ 超高安全性  │
│ Ed25519   │ 256bit       │ ★★★★★ │ ★★★★☆ │ ★★★★★ │ 推荐使用!  │
│ ECDSA     │ 256bit       │ ★★★★☆ │ ★★★★☆ │ ★★★★  │ 较新系统   │
│ Ed448     │ 456bit       │ ★★★★★ │ ★★☆☆☆ │ ★★★★  │ 专业用途   │
└────────────────────────────────────────────────────────────────────┘

兼容性说明:
  • RSA 4096: 所有系统都支持（最广泛）
  • RSA 8192: 大多数系统支持（某些旧系统可能不支持）
  • Ed25519: 现代系统（推荐！速度快、安全性强）
  • ECDSA: 现代系统支持（但不如Ed25519快）
  • Ed448: 需要较新的SSH客户端支持

安全级别分析:
  ★★★★★ 超强 - Ed25519, RSA 8192, Ed448
  ★★★★☆ 很强 - RSA 4096, ECDSA
  ★★★☆☆ ���   - RSA 2048 (已过时)

EOF
    
    echo -e "${YELLOW}请选择密钥算法:${NC}"
    echo "  1) RSA 4096位  (最兼容，推荐用于服务器)"
    echo "  2) RSA 8192位  (超强安全性，生成较慢)"
    echo "  3) Ed25519     (推荐！最快最安全)"
    echo "  4) ECDSA       (现代SSH客户端支持)"
    echo "  5) Ed448       (企业级安全)"
    
    read -p "请输入选项 (1-5): " algo_choice
    
    case $algo_choice in
        1) ALGO="rsa"; KEY_BITS="4096" ;;
        2) ALGO="rsa"; KEY_BITS="8192" ;;
        3) ALGO="ed25519"; KEY_BITS="256" ;;
        4) ALGO="ecdsa"; KEY_BITS="256" ;;
        5) ALGO="ed448"; KEY_BITS="456" ;;
        *) 
            log_error "无效选择"
            return 1
            ;;
    esac
}

generate_keypair() {
    init_ssh_dir
    
    # 检查是否已存在密钥
    if [[ -f "$SSH_DIR/id_$ALGO" ]]; then
        log_warn "密钥已存在: $SSH_DIR/id_$ALGO"
        read -p "是否覆盖? (y/n): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            log_info "保留现有密钥，退出"
            return 1
        fi
        backup_old_keys
    fi
    
    log_info "生成 ${ALGO^^} 密钥对 (${KEY_BITS}位)..."
    
    # 根据算法生成不同的密钥
    case $ALGO in
        rsa)
            ssh-keygen -t rsa -b "$KEY_BITS" -N "" -f "$SSH_DIR/id_rsa" -C "root@$(hostname)" 2>/dev/null
            chmod 600 "$SSH_DIR/id_rsa"
            chmod 644 "$SSH_DIR/id_rsa.pub"
            ;;
        ed25519)
            ssh-keygen -t ed25519 -N "" -f "$SSH_DIR/id_ed25519" -C "root@$(hostname)" 2>/dev/null
            chmod 600 "$SSH_DIR/id_ed25519"
            chmod 644 "$SSH_DIR/id_ed25519.pub"
            ;;
        ecdsa)
            ssh-keygen -t ecdsa -b 256 -N "" -f "$SSH_DIR/id_ecdsa" -C "root@$(hostname)" 2>/dev/null
            chmod 600 "$SSH_DIR/id_ecdsa"
            chmod 644 "$SSH_DIR/id_ecdsa.pub"
            ;;
        ed448)
            ssh-keygen -t ed448 -N "" -f "$SSH_DIR/id_ed448" -C "root@$(hostname)" 2>/dev/null
            chmod 600 "$SSH_DIR/id_ed448"
            chmod 644 "$SSH_DIR/id_ed448.pub"
            ;;
    esac
    
    log_success "密钥对生成完成"
    return 0
}

backup_old_keys() {
    local timestamp=$(date +%s)
    local backup_dir="$SSH_DIR/backup_$timestamp"
    mkdir -p "$backup_dir"
    
    cp "$SSH_DIR/id_$ALGO" "$backup_dir/" 2>/dev/null || true
    cp "$SSH_DIR/id_${ALGO}.pub" "$backup_dir/" 2>/dev/null || true
    
    log_success "旧密钥已备份到: $backup_dir"
}

################################################################################
#                          系统配置                                             #
################################################################################

configure_ssh() {
    print_header "Step 3: SSH 系统配置"
    
    log_info "配置SSH允许密钥认证和Root登录..."
    
    # 备份原配置
    if [[ -f "$SSH_CONFIG" ]]; then
        sudo cp "$SSH_CONFIG" "$SSH_CONFIG.bak.$(date +%s)"
        log_success "配置文件已备份"
    fi
    
    # 修改配置项
    local configs=(
        "PermitRootLogin yes"
        "PubkeyAuthentication yes"
        "PasswordAuthentication no"
        "PermitEmptyPasswords no"
    )
    
    for config in "${configs[@]}"; do
        key="${config%% *}"
        value="${config#* }"
        
        # 取消注释并修改或添加新行
        if sudo grep -q "^#$key " "$SSH_CONFIG"; then
            sudo sed -i "s/^#$key .*/$config/" "$SSH_CONFIG"
        elif ! sudo grep -q "^$key " "$SSH_CONFIG"; then
            echo "$config" | sudo tee -a "$SSH_CONFIG" >/dev/null
        fi
        
        log_success "已配置: $config"
    done
    
    # 重启SSH服务
    log_info "重启SSH服务..."
    sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null
    
    if sudo systemctl is-active --quiet ssh 2>/dev/null || sudo systemctl is-active --quiet sshd 2>/dev/null; then
        log_success "SSH服务已重启"
    else
        log_error "SSH服务重启失败"
        return 1
    fi
}

setup_authorized_keys() {
    print_header "Step 3: 配置授权密钥"
    
    local key_file="$SSH_DIR/id_${ALGO}.pub"
    
    if [[ ! -f "$key_file" ]]; then
        log_error "公钥文件不存在: $key_file"
        return 1
    fi
    
    local public_key=$(cat "$key_file")
    
    # 创建authorized_keys文件
    if [[ ! -f "$SSH_DIR/authorized_keys" ]]; then
        touch "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
        log_success "创建 authorized_keys 文件"
    fi
    
    # 添加公钥
    if ! grep -F "$public_key" "$SSH_DIR/authorized_keys" >/dev/null 2>&1; then
        echo "$public_key" >> "$SSH_DIR/authorized_keys"
        log_success "公钥已添加到 authorized_keys"
    else
        log_warn "公钥已存在于 authorized_keys"
    fi
    
    # 设置权限
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    
    log_success "已配置公钥认证"
}

################################################################################
#                          显示私钥                                             #
################################################################################

display_private_key() {
    print_header "Step 4: 私钥内容"
    
    local key_file="$SSH_DIR/id_${ALGO}"
    
    if [[ ! -f "$key_file" ]]; then
        log_error "私钥文件不存在: $key_file"
        return 1
    fi
    
    log_warn "重要提示: 请妥善保管您的私钥，永远不要分享给任何人！"
    echo ""
    
    # 显示分隔线和私钥内容
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${RED}                          私钥内容 (${ALGO^^})${NC}"
    echo -e "${RED}════════════════════════════════════════════════════════════════${NC}\n"
    
    cat "$key_file"
    
    echo -e "\n${RED}════════════════════════════════════════════════════════════════${NC}"
    
    # 显示文件信息
    echo ""
    echo -e "${CYAN}文件信息:${NC}"
    echo "  路径: $key_file"
    echo "  大小: $(ls -lh $key_file | awk '{print $5}')"
    echo "  权限: $(ls -l $key_file | awk '{print $1}')"
    
    # 显示公钥指纹
    local pub_file="$SSH_DIR/id_${ALGO}.pub"
    if [[ -f "$pub_file" ]]; then
        echo ""
        echo -e "${CYAN}公钥信息:${NC}"
        echo "  路径: $pub_file"
        ssh-keygen -lf "$pub_file" 2>/dev/null | head -1 | awk '{print "  指纹: " $2}'
    fi
}

################################################################################
#                          安全提示                                             #
################################################################################

show_security_warning() {
    print_header "安全提示"
    
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║                      重要安全警告                              ║
╚════════════════════════════════════════════════════════════════╝

1. 私钥保护
   ✓ 将上面显示的私钥内容立即保存到安全的地方
   ✓ 建议使用密码管理器（1Password、Bitwarden等）存储
   ✓ 永远不要通过不安全的通道传输私钥
   ✓ 删除此脚本运行后的历史记录: history -c

2. 文件权限
   ✓ 私钥权限应为 600 (--rw-------)
   ✓ .ssh 目录权限应为 700 (drwx------)
   ✓ 定期检查权限: ls -la ~/.ssh

3. Root 远程登录
   ✓ 已配置允许使用密钥远程Root登录
   ✓ 密码认证已禁用，只能使用密钥认证
   ✓ 定期审计 authorized_keys 中的密钥

4. 备份与恢复
   ✓ SSH配置文件已自动备份
   ✓ 旧密钥已备份（如有）
   ✓ 妥善保管备份文件

5. 日常使用
   远程登录命令:
   $ ssh -i ~/.ssh/id_${ALGO} root@<服务器IP>
   
   或使用默认密钥（如已配置）:
   $ ssh root@<服务器IP>

════════════════════════════════════════════════════════════════

EOF

    read -p "已阅读安全提示，按 Enter 继续..."
}

################################################################################
#                          主程序流程                                           #
################################################################################

main() {
    clear
    
    echo -e "${BLUE}"
    cat << 'EOF'
  ╔════════════════════════════════════════════════════════════╗
  ║                                                            ║
  ║         SSH 密钥生成与系统配置工具 v1.0                    ║
  ║                                                            ║
  ║  功能:                                                      ║
  ║   1. 检查/安装/启动 SSH 服务                               ║
  ║   2. 生成多种算法密钥对                                     ║
  ║   3. 配置系统密钥认证和Root登录                             ║
  ║   4. 显示私钥内容                                           ║
  ║                                                            ║
  ╚════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}\n"
    
    # 步骤 1: 系统检测与SSH安装
    detect_distro || exit 1
    check_ssh_service
    
    # 步骤 2: 选择密钥算法并生成
    show_algorithm_info
    generate_keypair || exit 1
    
    # 步骤 3: 系统配置
    configure_ssh
    setup_authorized_keys
    
    # 步骤 4: 显示私钥
    display_private_key
    
    # 安全提示
    show_security_warning
    
    print_header "完成"
    log_success "所有步骤已完成！"
    echo "密钥已保存到: $SSH_DIR/id_${ALGO}"
    echo "可以使用以下命令远程登录:"
    echo "  $ ssh root@<服务器IP>"
}

main "$@"