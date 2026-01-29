#!/bin/bash

################################################################################
#                                                                              #
#               SSH 管理工具 - 简化版本                                         #
#               SSH Admin Tool - Simplified Version                           #
#                                                                              #
#  功能包括:                                                                   #
#  1. SSH 服务管理（安装、启动、配置）                                         #
#  2. SSH 密钥生成（2048/4096/Ed25519）                                       #
#  3. SSH 密钥管理（备份、恢复、删除、重新生成）                               #
#  4. 公钥认证配置（配置、添加、查看、删除）                                   #
#  5. 查看与验证（密钥信息、验证、内容显示）                                   #
#  6. 交互式菜单界面                                                           #
#                                                                              #
#  版本: v1.0                                                                  #
#  更新时间: 2025-04-07                                                        #
#                                                                              #
################################################################################

# 颜色定义
RED='\033[1;31m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
SSH_SERVICE=""
PKG_MANAGER=""
SSH_DIR="$HOME/.ssh"
SSH_BACKUP_DIR="$SSH_DIR/backup"

################################################################################
#                          日志与输出函数                                       #
################################################################################

print_info() {
    echo -e "${CYAN}[信息]${NC} $@"
}

print_success() {
    echo -e "${GREEN}[成功]${NC} $@"
}

print_warning() {
    echo -e "${YELLOW}[警告]${NC} $@"
}

print_error() {
    echo -e "${RED}[错误]${NC} $@"
}

print_header() {
    echo -e "\n${BLUE}==================================================================${NC}"
    echo -e "${BLUE}$@${NC}"
    echo -e "${BLUE}==================================================================${NC}\n"
}

################################################################################
#                          系统检测与初始化                                     #
################################################################################

detect_system() {
    if [[ -f /etc/debian_version ]]; then
        SSH_SERVICE="ssh"
        PKG_MANAGER="apt-get"
        return 0
    elif [[ -f /etc/redhat-release ]]; then
        SSH_SERVICE="sshd"
        PKG_MANAGER="yum"
        return 0
    else
        print_error "不支持的系统类型"
        return 1
    fi
}

initialize_directories() {
    mkdir -p "$SSH_DIR" || {
        print_error "无法创建 $SSH_DIR 目录"
        return 1
    }
    chmod 700 "$SSH_DIR"
    mkdir -p "$SSH_BACKUP_DIR"
    return 0
}

################################################################################
#                          SSH 服务管理                                         #
################################################################################

install_and_start_ssh() {
    print_header "SSH 服务管理"
    
    # 检查SSH客户端
    if ! command -v ssh >/dev/null 2>&1; then
        print_info "安装SSH客户端..."
        if [[ "$PKG_MANAGER" == "apt-get" ]]; then
            sudo "$PKG_MANAGER" update -qq
            sudo "$PKG_MANAGER" install -y openssh-client >/dev/null 2>&1
        elif [[ "$PKG_MANAGER" == "yum" ]]; then
            sudo "$PKG_MANAGER" install -y openssh-clients >/dev/null 2>&1
        fi
    fi
    print_success "SSH客户端已安装"
    
    # 检查SSH服务端
    if ! sudo systemctl list-units --full --all 2>/dev/null | grep -Fq "${SSH_SERVICE}.service"; then
        print_info "安装SSH服务端..."
        if [[ "$PKG_MANAGER" == "apt-get" ]]; then
            sudo "$PKG_MANAGER" install -y openssh-server >/dev/null 2>&1
        elif [[ "$PKG_MANAGER" == "yum" ]]; then
            sudo "$PKG_MANAGER" install -y openssh-server >/dev/null 2>&1
        fi
    fi
    print_success "SSH服务端已安装"
    
    # 启动服务
    if ! sudo systemctl is-active --quiet "$SSH_SERVICE"; then
        print_info "启动SSH服务..."
        sudo systemctl start "$SSH_SERVICE"
        sudo systemctl enable "$SSH_SERVICE" >/dev/null 2>&1
    fi
    print_success "SSH服务已启动"
}

configure_ssh_service() {
    print_header "SSH 服务配置"
    
    local sshd_config="/etc/ssh/sshd_config"
    
    # 配置项列表
    local -a configs=(
        "PermitRootLogin:yes"
        "PubkeyAuthentication:yes"
        "PasswordAuthentication:no"
    )
    
    for config in "${configs[@]}"; do
        IFS=':' read -r key value <<< "$config"
        
        if sudo grep -q "^#$key " "$sshd_config"; then
            sudo sed -i "s/^#$key .*/$key $value/" "$sshd_config"
        elif ! sudo grep -q "^$key " "$sshd_config"; then
            echo "$key $value" | sudo tee -a "$sshd_config" >/dev/null
        fi
        
        if sudo grep -q "^$key $value" "$sshd_config"; then
            print_success "配置生效: $key $value"
        fi
    done
    
    # 重启服务
    print_info "重启SSH服务..."
    sudo systemctl restart "$SSH_SERVICE"
    print_success "SSH服务已重启"
}

################################################################################
#                          SSH 密钥生成                                         #
################################################################################

generate_ssh_keys() {
    local key_type="${1:-rsa}"
    local key_bits="${2:-4096}"
    
    print_header "SSH 密钥对生成"
    
    initialize_directories || return 1
    
    # 检查旧密钥
    if [[ -f "$SSH_DIR/id_$key_type" ]]; then
        print_warning "检测到已存在的SSH密钥对"
        read -p "是否覆盖现有密钥？(y/n): " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            print_info "保留现有密钥，退出"
            return 0
        fi
        backup_ssh_keys
    fi
    
    # 生成密钥
    print_info "生成 ${key_bits} 位 ${key_type^^} 密钥对..."
    local start_time=$(date +%s)
    
    ssh-keygen -t "$key_type" -b "$key_bits" -N "" -f "$SSH_DIR/id_$key_type" <<< $'\n' >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_success "密钥对生成完成 (耗时: ${duration}秒)"
        chmod 600 "$SSH_DIR/id_$key_type"
        chmod 644 "$SSH_DIR/id_${key_type}.pub"
        return 0
    else
        print_error "密钥生成失败"
        return 1
    fi
}

################################################################################
#                          SSH 密钥管理                                         #
################################################################################

backup_ssh_keys() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    print_header "SSH 密钥备份"
    
    if [[ ! -d "$SSH_BACKUP_DIR" ]]; then
        mkdir -p "$SSH_BACKUP_DIR"
    fi
    
    print_info "备份SSH密钥..."
    
    [[ -f "$SSH_DIR/id_rsa" ]] && cp "$SSH_DIR/id_rsa" "$SSH_BACKUP_DIR/id_rsa.bak.$timestamp"
    [[ -f "$SSH_DIR/id_rsa.pub" ]] && cp "$SSH_DIR/id_rsa.pub" "$SSH_BACKUP_DIR/id_rsa.pub.bak.$timestamp"
    [[ -f "$SSH_DIR/authorized_keys" ]] && cp "$SSH_DIR/authorized_keys" "$SSH_BACKUP_DIR/authorized_keys.bak.$timestamp"
    
    print_success "备份完成: $SSH_BACKUP_DIR"
}

restore_ssh_keys() {
    print_header "SSH 密钥恢复"
    
    if [[ ! -d "$SSH_BACKUP_DIR" ]] || [[ -z "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ]]; then
        print_error "没有可用的备份文件"
        return 1
    fi
    
    echo "可用的备份文件："
    local -a backups=()
    local count=1
    
    for backup in "$SSH_BACKUP_DIR"/*.bak.*; do
        if [[ -f "$backup" ]]; then
            backups+=("$backup")
            echo "$count) $(basename $backup)"
            ((count++))
        fi
    done
    
    read -p "选择要恢复的备份编号: " backup_choice
    
    if [[ ! "$backup_choice" =~ ^[0-9]+$ ]] || [[ $backup_choice -lt 1 ]] || [[ $backup_choice -gt ${#backups[@]} ]]; then
        print_error "无效的选择"
        return 1
    fi
    
    local selected_backup="${backups[$((backup_choice - 1))]}"
    local filename=$(basename "$selected_backup")
    local original_name="${filename%.bak.*}"
    
    read -p "确认恢复 $original_name ? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "恢复已取消"
        return 0
    fi
    
    if cp "$selected_backup" "$SSH_DIR/$original_name"; then
        [[ "$original_name" == "id_rsa" ]] && chmod 600 "$SSH_DIR/$original_name" || chmod 644 "$SSH_DIR/$original_name"
        print_success "密钥恢复完成"
        return 0
    else
        print_error "密钥恢复失败"
        return 1
    fi
}

delete_ssh_keys() {
    print_header "SSH 密钥删除"
    
    if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
        print_warning "未找到SSH密钥文件"
        return 0
    fi
    
    print_warning "即将删除SSH密钥:"
    ls -lh "$SSH_DIR"/id_* 2>/dev/null
    
    read -p "确认删除？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "删除已取消"
        return 0
    fi
    
    read -p "再次确认删除 (这是不可逆操作) (y/n): " confirm2
    if [[ ! "$confirm2" =~ ^[Yy]$ ]]; then
        print_info "删除已取消"
        return 0
    fi
    
    rm -f "$SSH_DIR"/id_rsa "$SSH_DIR"/id_rsa.pub "$SSH_DIR"/id_ed25519 "$SSH_DIR"/id_ed25519.pub
    print_success "SSH密钥已删除"
}

delete_and_regenerate() {
    print_header "SSH 密钥删除与重新生成"
    
    if [[ -f "$SSH_DIR/id_rsa" ]]; then
        backup_ssh_keys
    fi
    
    rm -f "$SSH_DIR/id_rsa" "$SSH_DIR/id_rsa.pub"
    print_success "旧密钥已删除"
    
    generate_ssh_keys "rsa" "4096" || return 1
    
    setup_public_key_auth
}

################################################################################
#                          公钥认证配置                                         #
################################################################################

setup_public_key_auth() {
    print_header "公钥认证配置"
    
    initialize_directories || return 1
    
    if [[ ! -f "$SSH_DIR/id_rsa.pub" ]]; then
        print_error "公钥文件不存在，请先生成密钥"
        return 1
    fi
    
    if [[ ! -f "$SSH_DIR/authorized_keys" ]]; then
        touch "$SSH_DIR/authorized_keys"
    fi
    
    local public_key=$(cat "$SSH_DIR/id_rsa.pub")
    
    if ! grep -F "$public_key" "$SSH_DIR/authorized_keys" >/dev/null 2>&1; then
        echo "$public_key" >> "$SSH_DIR/authorized_keys"
        print_success "公钥已添加"
    else
        print_warning "公钥已存在"
    fi
    
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    print_success "公钥认证配置完成"
}

add_remote_public_key() {
    print_header "添加远程公钥"
    
    initialize_directories || return 1
    
    echo "选择添加方式:"
    echo "1) 从文件导入"
    echo "2) 直接粘贴"
    
    read -p "请选择 (1-2): " choice
    
    local public_key=""
    
    case $choice in
        1)
            read -p "输入公钥文件路径: " key_file
            if [[ ! -f "$key_file" ]]; then
                print_error "文件不存在"
                return 1
            fi
            public_key=$(cat "$key_file")
            ;;
        2)
            echo "粘贴公钥内容 (Ctrl+D 结束):"
            public_key=$(cat)
            ;;
        *)
            print_error "无效选择"
            return 1
            ;;
    esac
    
    if [[ -z "$public_key" ]]; then
        print_error "公钥内容为空"
        return 1
    fi
    
    if ! echo "$public_key" | grep -qE "^ssh-rsa |^ecdsa-sha2-|^ssh-ed25519 "; then
        print_error "公钥格式不正确"
        return 1
    fi
    
    if [[ ! -f "$SSH_DIR/authorized_keys" ]]; then
        touch "$SSH_DIR/authorized_keys"
    fi
    
    if ! grep -F "$public_key" "$SSH_DIR/authorized_keys" >/dev/null 2>&1; then
        echo "$public_key" >> "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
        print_success "远程公钥已添加"
    else
        print_warning "该公钥已存在"
    fi
}

view_authorized_keys() {
    print_header "授权密钥列表"
    
    if [[ ! -f "$SSH_DIR/authorized_keys" ]]; then
        print_warning "authorized_keys 文件不存在"
        return 0
    fi
    
    echo "authorized_keys 内容:"
    echo "=================================================="
    cat "$SSH_DIR/authorized_keys"
    echo "=================================================="
    echo "总计: $(grep -c '^ssh-' "$SSH_DIR/authorized_keys" 2>/dev/null || echo 0) 个授权密钥"
}

remove_authorized_key() {
    print_header "删除授权密钥"
    
    if [[ ! -f "$SSH_DIR/authorized_keys" ]]; then
        print_error "authorized_keys 文件不存在"
        return 1
    fi
    
    local key_count=$(grep -c '^ssh-' "$SSH_DIR/authorized_keys" 2>/dev/null || echo 0)
    
    if [[ $key_count -eq 0 ]]; then
        print_warning "没有授权密钥"
        return 0
    fi
    
    echo "当前授权密钥:"
    grep -n '^ssh-' "$SSH_DIR/authorized_keys" | nl
    
    read -p "输入要删除的编号: " key_number
    
    if [[ ! "$key_number" =~ ^[0-9]+$ ]]; then
        print_error "无效的编号"
        return 1
    fi
    
    local line_number=$(grep -n '^ssh-' "$SSH_DIR/authorized_keys" | sed -n "${key_number}p" | cut -d: -f1)
    
    if [[ -z "$line_number" ]]; then
        print_error "密钥不存在"
        return 1
    fi
    
    sed -i "${line_number}d" "$SSH_DIR/authorized_keys"
    print_success "密钥已删除"
}

################################################################################
#                          查看与验证                                           #
################################################################################

display_key_info() {
    print_header "SSH 密钥信息"
    
    if [[ -f "$SSH_DIR/id_rsa" ]]; then
        echo -e "${CYAN}========== 私钥信息 ==========${NC}"
        echo "路径: $SSH_DIR/id_rsa"
        
        if command -v openssl >/dev/null 2>&1; then
            local key_info=$(openssl rsa -in "$SSH_DIR/id_rsa" -text -noout 2>/dev/null)
            if [[ -n "$key_info" ]]; then
                echo "密钥长度: $(echo "$key_info" | grep "Private-Key" | awk '{print $2}')"
            fi
        fi
        
        echo "文件大小: $(ls -lh $SSH_DIR/id_rsa | awk '{print $5}')"
        echo ""
    fi
    
    if [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
        echo -e "${CYAN}========== 公钥信息 ==========${NC}"
        echo "路径: $SSH_DIR/id_rsa.pub"
        
        local fingerprint=$(ssh-keygen -lf "$SSH_DIR/id_rsa.pub" 2>/dev/null)
        if [[ -n "$fingerprint" ]]; then
            echo "指纹: $(echo $fingerprint | awk '{print $2}')"
        fi
        
        echo "内容: $(head -c 50 $SSH_DIR/id_rsa.pub)..."
        echo ""
    fi
    
    if [[ -f "$SSH_DIR/authorized_keys" ]]; then
        echo -e "${CYAN}========== 授权密钥统计 ==========${NC}"
        echo "授权密钥数量: $(grep -c '^ssh-' "$SSH_DIR/authorized_keys" 2>/dev/null || echo 0)"
    fi
}

display_key_contents() {
    print_header "SSH 密钥文件内容"
    
    echo -e "${CYAN}========== 私钥内容 ==========${NC}"
    if [[ -f "$SSH_DIR/id_rsa" ]]; then
        cat "$SSH_DIR/id_rsa"
    else
        echo "私钥文件不存在"
    fi
    
    echo -e "\n${CYAN}========== 公钥内容 ==========${NC}"
    if [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
        cat "$SSH_DIR/id_rsa.pub"
    else
        echo "公钥文件不存在"
    fi
    
    echo -e "\n${CYAN}========== 授权密钥内容 (最后5行) ==========${NC}"
    if [[ -f "$SSH_DIR/authorized_keys" ]]; then
        tail -n 5 "$SSH_DIR/authorized_keys"
    else
        echo "authorized_keys 文件不存在"
    fi
    
    echo -e "\n${RED}=====================================\n"
    echo -e "重要: 请妥善保管您的私钥！"
    echo -e "=====================================${NC}\n"
}

verify_key_pair() {
    print_header "SSH 密钥对验证"
    
    if [[ ! -f "$SSH_DIR/id_rsa" ]] || [[ ! -f "$SSH_DIR/id_rsa.pub" ]]; then
        print_error "密钥文件不存在"
        return 1
    fi
    
    echo -e "${CYAN}[验证私钥]${NC}"
    if openssl rsa -in "$SSH_DIR/id_rsa" -check -noout >/dev/null 2>&1; then
        print_success "私钥结构有效"
    else
        print_error "私钥已损坏"
        return 1
    fi
    
    echo -e "${CYAN}[验证公钥]${NC}"
    if ssh-keygen -l -f "$SSH_DIR/id_rsa.pub" >/dev/null 2>&1; then
        print_success "公钥结构有效"
    else
        print_error "公钥已损坏"
        return 1
    fi
    
    echo -e "${CYAN}[验证授权密钥]${NC}"
    if [[ -f "$SSH_DIR/authorized_keys" ]]; then
        if grep -F "$(cat $SSH_DIR/id_rsa.pub)" "$SSH_DIR/authorized_keys" >/dev/null 2>&1; then
            print_success "公钥已在authorized_keys中"
        else
            print_warning "公钥不在authorized_keys中"
        fi
    else
        print_warning "authorized_keys 文件不存在"
    fi
}

################################################################################
#                          交互式菜单                                           #
################################################################################

show_menu() {
    clear
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                    ║${NC}"
    echo -e "${BLUE}║          SSH 管理工具 - 简化版本 v1.0              ║${NC}"
    echo -e "${BLUE}║                                                    ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}========== SSH 服务管理 ==========${NC}"
    echo "  1) 安装和启动 SSH 服务"
    echo "  2) 配置 SSH 服务"
    
    echo -e "\n${CYAN}========== SSH 密钥生成 ==========${NC}"
    echo "  3) 生成 RSA 2048位密钥"
    echo "  4) 生成 RSA 4096位密钥"
    echo "  5) 生成 Ed25519 密钥"
    
    echo -e "\n${CYAN}========== SSH 密钥管理 ==========${NC}"
    echo "  6) 备份 SSH 密钥"
    echo "  7) 恢复 SSH 密钥"
    echo "  8) 删除 SSH 密钥"
    echo "  9) 删除并重新生成密钥"
    
    echo -e "\n${CYAN}========== 公钥认证管理 ==========${NC}"
    echo " 10) 配���公钥认证"
    echo " 11) 添加远程公钥"
    echo " 12) 查看授权密钥"
    echo " 13) 删除授权密钥"
    
    echo -e "\n${CYAN}========== 查看与验证 ==========${NC}"
    echo " 14) 显示密钥信息"
    echo " 15) 显示密钥内容"
    echo " 16) 验证密钥对"
    
    echo -e "\n  0) 退出脚本\n"
    
    read -p "请选择操作 (0-16): " choice
    echo ""
}

################################################################################
#                          主程序                                              #
################################################################################

main() {
    detect_system || exit 1
    
    while true; do
        show_menu
        
        case $choice in
            1) install_and_start_ssh ;;
            2) configure_ssh_service ;;
            3) generate_ssh_keys "rsa" "2048" ;;
            4) generate_ssh_keys "rsa" "4096" ;;
            5) generate_ssh_keys "ed25519" "256" ;;
            6) backup_ssh_keys ;;
            7) restore_ssh_keys ;;
            8) delete_ssh_keys ;;
            9) delete_and_regenerate ;;
            10) setup_public_key_auth ;;
            11) add_remote_public_key ;;
            12) view_authorized_keys ;;
            13) remove_authorized_key ;;
            14) display_key_info ;;
            15) display_key_contents ;;
            16) verify_key_pair ;;
            0)
                print_info "退出脚本"
                exit 0
                ;;
            *)
                print_error "无效的选择，请重试"
                ;;
        esac
        
        read -p "按 Enter 继续..."
    done
}

main "$@"