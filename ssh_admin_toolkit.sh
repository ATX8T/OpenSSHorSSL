#!/bin/bash

################################################################################
#                                                                              #
#               SSH 管理工具套件 - 综合版本                                     #
#               SSH Admin Toolkit - Comprehensive Version                     #
#                                                                              #
#  功能包括:                                                                   #
#  1. SSH密钥对生成与配置(2048/4096位)                                         #
#  2. SSH服务安装与启动管理                                                    #
#  3. SSH密钥删除与重新生成                                                    #
#  4. 公钥认证配置与验证                                                       #
#  5. SSH服务配置优化                                                          #
#  6. 密钥备份与恢复                                                           #
#                                                                              #
#  版本: v2.0                                                                  #
#  更新时间: 2025-04-07                                                        #
#                                                                              #
################################################################################

# 颜色定义
RED='\033[1;31m'
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 全局变量
SSH_SERVICE=""
PKG_MANAGER=""
SSH_DIR="$HOME/.ssh"
SSH_BACKUP_DIR="$SSH_DIR/backup"
LOG_FILE="/var/log/ssh_admin_toolkit.log"

################################################################################
#                          日志与输出函数                                       #
################################################################################

# 日志记录函数
log_message() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ -w "$(dirname "$LOG_FILE")" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# 打印信息
print_info() {
    echo -e "${CYAN}[信息]${NC} $@"
    log_message "INFO" "$@"
}

# 打印成功
print_success() {
    echo -e "${GREEN}[成功]${NC} $@"
    log_message "SUCCESS" "$@"
}

# 打印警告
print_warning() {
    echo -e "${YELLOW}[警告]${NC} $@"
    log_message "WARNING" "$@"
}

# 打印错误
print_error() {
    echo -e "${RED}[错误]${NC} $@"
    log_message "ERROR" "$@"
}

# 打印标题
print_header() {
    echo -e "\n${BLUE}==================================================================${NC}"
    echo -e "${BLUE}$@${NC}"
    echo -e "${BLUE}==================================================================${NC}\n"
}

################################################################################
#                          系统检测与初始化                                     #
################################################################################

# 检测系统类型
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
        print_error "不支持的系统类型，无法自动安装SSH"
        return 1
    fi
}

# 检查权限
check_permissions() {
    if [[ $EUID -ne 0 ]] && [[ "$1" != "skip" ]]; then
        print_warning "某些操作需要sudo权限，将在需要时请求"
    fi
}

# 初始化目录
initialize_directories() {
    mkdir -p "$SSH_DIR" || {
        print_error "无法创建 $SSH_DIR 目录"
        return 1
    }
    chmod 700 "$SSH_DIR"
    
    mkdir -p "$SSH_BACKUP_DIR" || {
        print_warning "无法创建备份目录"
    }
    
    return 0
}

################################################################################
#                          SSH服务管理函数                                      #
################################################################################

# 安装SSH服务
install_ssh() {
    print_header "SSH 服务安装与配置"
    
    # 检查SSH客户端
    if command -v ssh >/dev/null 2>&1; then
        print_success "SSH客户端已安装"
    else
        print_info "SSH客户端未安装，正在安装..."
        if [[ "$PKG_MANAGER" == "apt-get" ]]; then
            sudo "$PKG_MANAGER" update -qq || {
                print_error "包管理器更新失败"
                return 1
            }
            sudo "$PKG_MANAGER" install -y openssh-client >/dev/null 2>&1 || {
                print_error "SSH客户端安装失败"
                return 1
            }
        elif [[ "$PKG_MANAGER" == "yum" ]]; then
            sudo "$PKG_MANAGER" install -y openssh-clients >/dev/null 2>&1 || {
                print_error "SSH客户端安装失败"
                return 1
            }
        fi
        print_success "SSH客户端安装完成"
    fi
    
    # 检查SSH服务端
    if ! sudo systemctl list-units --full --all 2>/dev/null | grep -Fq "${SSH_SERVICE}.service"; then
        print_info "SSH服务端未安装，正在安装..."
        if [[ "$PKG_MANAGER" == "apt-get" ]]; then
            sudo "$PKG_MANAGER" install -y openssh-server >/dev/null 2>&1 || {
                print_error "SSH服务端安装失败"
                return 1
            }
        elif [[ "$PKG_MANAGER" == "yum" ]]; then
            sudo "$PKG_MANAGER" install -y openssh-server >/dev/null 2>&1 || {
                print_error "SSH服务端安装失败"
                return 1
            }
        fi
        print_success "SSH服务端安装完成"
    else
        print_success "SSH服务端已安装"
    fi
    
    # 启动SSH服务
    if ! sudo systemctl is-active --quiet "$SSH_SERVICE"; then
        print_info "启动SSH服务..."
        sudo systemctl start "$SSH_SERVICE" || {
            print_error "SSH服务启动失败"
            return 1
        }
        sudo systemctl enable "$SSH_SERVICE" >/dev/null 2>&1
        print_success "SSH服务已启动并设置为开机自启"
    else
        print_success "SSH服务已运行"
    fi
    
    return 0
}

# 重启SSH服务
restart_ssh_service() {
    print_info "重启SSH服务..."
    sudo systemctl restart "$SSH_SERVICE" || {
        print_error "SSH服务重启失败"
        return 1
    }
    
    if sudo systemctl is-active --quiet "$SSH_SERVICE"; then
        print_success "SSH服务已重启并正常运行"
        return 0
    else
        print_error "SSH服务重启后未运行，请检查配置"
        sudo systemctl status "$SSH_SERVICE"
        return 1
    fi
}

# 配置SSH服务
configure_ssh_service() {
    print_header "SSH 服务配置"
    
    local sshd_config="/etc/ssh/sshd_config"
    
    # 配置项列表
    local -a config_items=(
        "PermitRootLogin:yes:允许Root用户登录"
        "PubkeyAuthentication:yes:启用公钥认证"
        "PasswordAuthentication:no:禁用密码认证"
        "PermitEmptyPasswords:no:禁用空密码"
        "X11Forwarding:no:禁用X11转发"
    )
    
    for item in "${config_items[@]}"; do
        IFS=':' read -r key value comment <<< "$item"
        
        # 检查配置项是否存在
        if sudo grep -q "^#$key " "$sshd_config"; then
            print_info "取消注释并配置: $comment"
            sudo sed -i "s/^#$key .*/$key $value/" "$sshd_config"
        elif ! sudo grep -q "^$key " "$sshd_config"; then
            print_info "添加配置项: $comment"
            echo "$key $value" | sudo tee -a "$sshd_config" >/dev/null
        fi
        
        # 验证配置
        if sudo grep -q "^$key $value" "$sshd_config"; then
            print_success "配置生效: $comment"
        else
            print_warning "配置 $key 未能完全生效，请手动检查"
        fi
    done
    
    return 0
}

################################################################################
#                          SSH密钥管理函数                                      #
################################################################################

# 生成SSH密钥对
generate_ssh_keys() {
    local key_type="${1:-rsa}"
    local key_bits="${2:-4096}"
    
    print_header "SSH 密钥对生成"
    
    initialize_directories || return 1
    
    # 检查是否存在旧密钥
    if [[ -f "$SSH_DIR/id_$key_type" ]]; then
        print_warning "检测到已存在的SSH密钥对"
        
        # 显示现有密钥信息
        if command -v openssl >/dev/null 2>&1; then
            local key_info=$(openssl rsa -in "$SSH_DIR/id_$key_type" -text -noout 2>/dev/null)
            if [[ -n "$key_info" ]]; then
                local key_length=$(echo "$key_info" | grep "Private-Key" | awk '{print $2}')
                print_info "当前密钥长度: $key_length"
            fi
        fi
        
        local fingerprint=$(ssh-keygen -lf "$SSH_DIR/id_${key_type}.pub" 2>/dev/null)
        if [[ -n "$fingerprint" ]]; then
            print_info "密钥指纹: $(echo $fingerprint | awk '{print $2}')"
        fi
        
        # 询问是否覆盖
        while true; do
            read -p "是否要覆盖现有密钥？(y/n): " overwrite
            case $overwrite in
                [Yy]*)
                    backup_ssh_keys || {
                        print_error "备份密钥失败，中止操作"
                        return 1
                    }
                    break
                    ;;
                [Nn]*)
                    print_info "保留现有密钥，退出"
                    return 0
                    ;;
                *)
                    echo "请输入 y 或 n"
                    ;;
            esac
        done
    fi
    
    # 生成密钥
    print_info "正在生成 ${key_bits} 位 ${key_type^^} 密钥对..."
    local start_time=$(date +%s)
    
    ssh-keygen -t "$key_type" -b "$key_bits" -N "" -f "$SSH_DIR/id_$key_type" <<< $'\n' >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_success "密钥对生成完成 (耗时: ${duration}秒)"
        
        # 设置权限
        chmod 600 "$SSH_DIR/id_$key_type"
        chmod 644 "$SSH_DIR/id_${key_type}.pub"
        
        return 0
    else
        print_error "密钥对生成失败"
        return 1
    fi
}

# 备份SSH密钥
backup_ssh_keys() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    if [[ ! -d "$SSH_BACKUP_DIR" ]]; then
        mkdir -p "$SSH_BACKUP_DIR" || {
            print_error "无法创建备份目录"
            return 1
        }
    fi
    
    print_info "备份SSH密钥到 $SSH_BACKUP_DIR"
    
    if [[ -f "$SSH_DIR/id_rsa" ]]; then
        cp "$SSH_DIR/id_rsa" "$SSH_BACKUP_DIR/id_rsa.bak.$timestamp"
        cp "$SSH_DIR/id_rsa.pub" "$SSH_BACKUP_DIR/id_rsa.pub.bak.$timestamp"
    fi
    
    if [[ -f "$SSH_DIR/authorized_keys" ]]; then
        cp "$SSH_DIR/authorized_keys" "$SSH_BACKUP_DIR/authorized_keys.bak.$timestamp"
    fi
    
    print_success "密钥备份完成: $SSH_BACKUP_DIR"
    return 0
}

# 恢复SSH密钥
restore_ssh_keys() {
    print_header "SSH 密钥恢复"
    
    if [[ ! -d "$SSH_BACKUP_DIR" ]] || [[ -z "$(ls -A "$SSH_BACKUP_DIR" 2>/dev/null)" ]]; then
        print_error "没有可用的备份文件"
        return 1
    fi
    
    # 列出备份文件
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
    
    if [[ ${#backups[@]} -eq 0 ]]; then
        print_error "没有找到备份文件"
        return 1
    fi
    
    # 选择备份
    read -p "选择要恢复的备份文件编号: " backup_choice
    
    if [[ ! "$backup_choice" =~ ^[0-9]+$ ]] || [[ $backup_choice -lt 1 ]] || [[ $backup_choice -gt ${#backups[@]} ]]; then
        print_error "无效的选择"
        return 1
    fi
    
    local selected_backup="${backups[$((backup_choice - 1))]}"
    local filename=$(basename "$selected_backup")
    local original_name="${filename%.bak.*}"
    
    # 确认恢复
    read -p "确认恢复 $original_name ? (y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "恢复已取消"
        return 0
    fi
    
    # 执行恢复
    if cp "$selected_backup" "$SSH_DIR/$original_name"; then
        if [[ "$original_name" == "id_rsa" ]]; then
            chmod 600 "$SSH_DIR/$original_name"
        else
            chmod 644 "$SSH_DIR/$original_name"
        fi
        print_success "密钥恢复完成"
        return 0
    else
        print_error "密钥恢复失败"
        return 1
    fi
}

# 删除SSH密钥
delete_ssh_keys() {
    print_header "SSH 密钥删除"
    
    if [[ ! -f "$SSH_DIR/id_rsa" ]] && [[ ! -f "$SSH_DIR/id_ed25519" ]]; then
        print_warning "未找到SSH密钥文件"
        return 0
    fi
    
    echo "即将删除的文件："
    ls -lh "$SSH_DIR"/id_* 2>/dev/null || true
    
    read -p "确认删除上述密钥文件？(y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "删除操作已取消"
        return 0
    fi
    
    # 二次确认
    read -p "这是不可逆操作，请再次确认 (y/n): " confirm2
    if [[ ! "$confirm2" =~ ^[Yy]$ ]]; then
        print_info "删除操作已取消"
        return 0
    fi
    
    rm -f "$SSH_DIR"/id_rsa "$SSH_DIR"/id_rsa.pub "$SSH_DIR"/id_ed25519 "$SSH_DIR"/id_ed25519.pub
    
    if [[ ! -f "$SSH_DIR/id_rsa" ]]; then
        print_success "SSH密钥已删除"
        return 0
    else
        print_error "SSH密钥删除失败"
        return 1
    fi
}

# 删除并重新生成SSH密钥
delete_and_regenerate_ssh() {
    print_header "SSH 密钥删除与重新生成"
    
    print_info "此操作将删除现有密钥并生成新密钥"
    
    # 备份旧密钥
    if [[ -f "$SSH_DIR/id_rsa" ]]; then
        backup_ssh_keys || {
            read -p "备份失败，是否继续？(y/n): " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                return 1
            fi
        }
    fi
    
    # 删除现有密钥
    rm -f "$SSH_DIR/id_rsa" "$SSH_DIR/id_rsa.pub"
    print_success "旧SSH密钥已删除"
    
    # 清理 authorized_keys
    if [[ -f "$SSH_DIR/authorized_keys" ]]; then
        # 注意：这里只清理一次，避免循环删除
        if [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
            grep -v "$(cat $SSH_DIR/id_rsa.pub 2>/dev/null)" "$SSH_DIR/authorized_keys" > "$SSH_DIR/authorized_keys.tmp"
            mv "$SSH_DIR/authorized_keys.tmp" "$SSH_DIR/authorized_keys"
            print_success "已从authorized_keys中移除旧公钥"
        fi
    fi
    
    # 生成新密钥
    generate_ssh_keys "rsa" "4096" || return 1
    
    # 配置公钥认证
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    cat "$SSH_DIR/id_rsa.pub" >> "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    
    # 验证
    if grep -q "$(cat $SSH_DIR/id_rsa.pub)" "$SSH_DIR/authorized_keys"; then
        print_success "新公钥已成功添加到authorized_keys"
    else
        print_error "新公钥添加失败！"
        return 1
    fi
    
    return 0
}

################################################################################
#                          公钥认证配置函数                                     #
################################################################################

# 配置公钥认证
setup_public_key_authentication() {
    print_header "公钥认证配置"
    
    initialize_directories || return 1
    
    # 检查密钥是否存在
    if [[ ! -f "$SSH_DIR/id_rsa.pub" ]]; then
        print_error "公钥文件不存在，请先生成密钥"
        return 1
    fi
    
    # 确保authorized_keys文件存在
    if [[ ! -f "$SSH_DIR/authorized_keys" ]]; then
        touch "$SSH_DIR/authorized_keys"
        print_info "创建 authorized_keys 文件"
    fi
    
    # 添加公钥到 authorized_keys
    local public_key=$(cat "$SSH_DIR/id_rsa.pub")
    
    if ! grep -F "$public_key" "$SSH_DIR/authorized_keys" >/dev/null 2>&1; then
        echo "$public_key" >> "$SSH_DIR/authorized_keys"
        print_success "公钥已添加到authorized_keys"
    else
        print_warning "公钥已存在于authorized_keys中"
    fi
    
    # 设置权限
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/authorized_keys"
    
    # 验证
    if grep -q "$(cat $SSH_DIR/id_rsa.pub)" "$SSH_DIR/authorized_keys"; then
        print_success "公钥认证配置完成"
        return 0
    else
        print_error "公钥认证配置失败"
        return 1
    fi
}

# 添加远程公钥
add_remote_public_key() {
    print_header "添加远程公钥"
    
    echo "请选择添加方式:"
    echo "1) 从文件导入"
    echo "2) 直接粘贴公钥内容"
    
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
            echo "请粘贴公钥内容 (结束时按Ctrl+D):"
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
    
    # 验证公钥格式
    if ! echo "$public_key" | grep -qE "^ssh-rsa |^ecdsa-sha2-|^ssh-ed25519 "; then
        print_error "公钥格式不正确"
        return 1
    fi
    
    # 添加到authorized_keys
    initialize_directories || return 1
    
    if ! grep -F "$public_key" "$SSH_DIR/authorized_keys" >/dev/null 2>&1; then
        echo "$public_key" >> "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
        print_success "远程公钥已添加"
    else
        print_warning "该公钥已存在"
    fi
    
    return 0
}

# 查看授权密钥
view_authorized_keys() {
    print_header "授权密钥列表"
    
    if [[ ! -f "$SSH_DIR/authorized_keys" ]]; then
        print_warning "authorized_keys 文件不存在"
        return 0
    fi
    
    echo "authorized_keys 内容："
    echo "=================================================="
    cat "$SSH_DIR/authorized_keys" | while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            # 提取注释和指纹
            local comment=$(echo "$line" | awk '{print $NF}')
            local fingerprint=$(echo "$line" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')
            printf "%-50s %s\n" "指纹: $fingerprint" "注释: $comment"
        fi
    done
    echo "=================================================="
    echo "总计: $(grep -c '^ssh-' $SSH_DIR/authorized_keys 2>/dev/null || echo 0) 个授权密钥"
    
    return 0
}

# 删除授权密钥
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
    
    read -p "输入要删除的密钥编号: " key_number
    
    if [[ ! "$key_number" =~ ^[0-9]+$ ]]; then
        print_error "无效的编号"
        return 1
    fi
    
    local line_number=$(grep -n '^ssh-' "$SSH_DIR/authorized_keys" | sed -n "${key_number}p" | cut -d: -f1)
    
    if [[ -z "$line_number" ]]; then
        print_error "密钥不存在"
        return 1
    fi
    
    # 删除指定行
    sed -i "${line_number}d" "$SSH_DIR/authorized_keys"
    print_success "密钥已删除"
    
    return 0
}

################################################################################
#                          密钥信息显示函数                                     #
################################################################################

# 显示SSH密钥信息
display_key_info() {
    print_header "SSH 密钥信息"
    
    # 私钥信息
    if [[ -f "$SSH_DIR/id_rsa" ]]; then
        echo -e "${CYAN}========== 私钥信息 ==========${NC}"
        echo "路径: $SSH_DIR/id_rsa"
        
        if command -v openssl >/dev/null 2>&1; then
            local key_info=$(openssl rsa -in "$SSH_DIR/id_rsa" -text -noout 2>/dev/null)
            if [[ -n "$key_info" ]]; then
                echo "密钥长度: $(echo "$key_info" | grep "Private-Key" | awk '{print $2}')"
                echo "密钥模式: RSA"
            fi
        fi
        
        echo "文件大小: $(ls -lh $SSH_DIR/id_rsa | awk '{print $5}')"
        echo "修改时间: $(ls -l $SSH_DIR/id_rsa | awk '{print $6, $7, $8}')"
        echo ""
    else
        echo -e "${YELLOW}私钥文件不存在${NC}"
    fi
    
    # 公钥信息
    if [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
        echo -e "${CYAN}========== 公钥信息 ==========${NC}"
        echo "路径: $SSH_DIR/id_rsa.pub"
        
        local fingerprint=$(ssh-keygen -lf "$SSH_DIR/id_rsa.pub" 2>/dev/null)
        if [[ -n "$fingerprint" ]]; then
            echo "指纹: $(echo $fingerprint | awk '{print $2}')"
            echo "密钥类型: $(echo $fingerprint | awk '{print $4}' | sed 's/[()]//g')"
        fi
        
        echo "公钥内容: $(head -c 50 $SSH_DIR/id_rsa.pub)..."
        echo ""
    else
        echo -e "${YELLOW}公钥文件不存在${NC}"
    fi
    
    # authorized_keys 信息
    if [[ -f "$SSH_DIR/authorized_keys" ]]; then
        echo -e "${CYAN}========== 授权密钥统计 ==========${NC}"
        local auth_count=$(grep -c '^ssh-' "$SSH_DIR/authorized_keys" 2>/dev/null || echo 0)
        echo "授权密钥数量: $auth_count"
        echo ""
    fi
}

# 显示密钥文件内容
display_key_contents() {
    print_header "SSH 密钥文件内容"
    
    echo -e "${CYAN}========== 私钥内容 ==========${NC}"
    if [[ -f "$SSH_DIR/id_rsa" ]]; then
        cat "$SSH_DIR/id_rsa"
    else
        echo -e "${YELLOW}私钥文件不存在${NC}"
    fi
    
    echo -e "\n${CYAN}========== 公钥内容 ==========${NC}"
    if [[ -f "$SSH_DIR/id_rsa.pub" ]]; then
        cat "$SSH_DIR/id_rsa.pub"
    else
        echo -e "${YELLOW}公钥文件不存在${NC}"
    fi
    
    echo -e "\n${CYAN}========== 授权密钥内容 (最后5行) ==========${NC}"
    if [[ -f "$SSH_DIR/authorized_keys" ]]; then
        tail -n 5 "$SSH_DIR/authorized_keys"
    else
        echo -e "${YELLOW}authorized_keys 文件不存在${NC}"
    fi
}

# 验证密钥对
verify_key_pair() {
    print_header "SSH 密钥对验证"
    
    if [[ ! -f "$SSH_DIR/id_rsa" ]] || [[ ! -f "$SSH_DIR/id_rsa.pub" ]]; then
        print_error "密钥文件不存在"
        return 1
    fi
    
    # 验证私钥
    echo -e "${CYAN}[验证私钥]${NC}"
    if openssl rsa -in "$SSH_DIR/id_rsa" -check -noout >/dev/null 2>&1; then
        print_success "私钥结构有效"
    else
        print_error "私钥已损坏"
        return 1
    fi
    
    # 验证公钥
    echo -e "${CYAN}[验证公钥]${NC}"
    if ssh-keygen -l -f "$SSH_DIR/id_rsa.pub" >/dev/null 2>&1; then
        print_success "公钥结构有效"
    else
        print_error "公钥已损坏"
        return 1
    fi
    
    # 验证密钥对匹配
    echo -e "${CYAN}[验证密钥对匹配]${NC}"
    local private_modulus=$(openssl rsa -modulus -noout -in "$SSH_DIR/id_rsa" 2>/dev/null | openssl sha256)
    local public_modulus=$(openssl rsa -pubin -modulus -noout -in <(ssh-keygen -e -m PKCS8 -f "$SSH_DIR/id_rsa.pub" 2>/dev/null) 2>/dev/null | openssl sha256)
    
    if [[ "$private_modulus" == "$public_modulus" ]]; then
        print_success "私钥和公钥匹配"
    else
        print_warning "无法验证密钥匹配状态，但密钥可能仍然有效"
    fi
    
    # 验证authorized_keys
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
    
    return 0
}

################################################################################
#                          密钥安全提示函数                                     #
################################################################################

# 显示密钥安全提示
display_security_warning() {
    print_header "密钥安全提示"
    
    echo -e "${RED}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║            重要安全提示                                ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${RED}[重要] 私钥安全注意事项:${NC}"
    echo -e "  1. 私钥 ($SSH_DIR/id_rsa) 是访问服务器的唯一凭证"
    echo -e "  2. 私钥一旦泄露，攻击者可以冒充您访问所有使用该密钥的服务器"
    echo -e "  3. 请立即将私钥内容复制并保存到安全的地方"
    echo -e "  4. 建议使用密码管理器 (如 1Password, Bitwarden) 存储私钥"
    echo -e "  5. 从不要通过不安全的渠道传输私钥"
    echo -e "  6. 建议定期更换密钥"
    echo -e "  7. 生产环境中不应将私钥保留在服务器上\n"
    
    echo -e "${RED}[安全建议]:${NC}"
    echo -e "  • 本地开发: 安全保管私钥，在.ssh目录设置700权限"
    echo -e "  • 服务器: 仅保留authorized_keys和公钥，删除私钥"
    echo -e "  • 备份: 定期备份密钥到离线存储"
    echo -e "  • 审计: 定期检查authorized_keys中的授权密钥"
    
    echo -e "\n${YELLOW}是否需要从服务器删除私钥文件？${NC}"
    read -p "这将增强安全性 (y/n): " delete_choice
    
    if [[ "$delete_choice" =~ ^[Yy]$ ]]; then
        # 二次确认
        read -p "您确定已经保存了私钥吗？删除后将无法恢复！(y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$SSH_DIR/id_rsa"
            print_success "私钥已删除，仅保留authorized_keys"
            print_warning "请确保您已经保存了私钥内容！"
        fi
    fi
}

################################################################################
#                          测试连接函数                                         #
################################################################################

# 测试SSH连接
test_ssh_connection() {
    print_header "SSH 连接测试"
    
    read -p "输入测试地址 (默认: localhost): " test_host
    test_host=${test_host:-"localhost"}
    
    read -p "输入端口 (默认: 22): " test_port
    test_port=${test_port:-"22"}
    
    read -p "输入用户名 (默认: $(whoami)): " test_user
    test_user=${test_user:-"$(whoami)"}
    
    print_info "连接到 $test_user@$test_host:$test_port ..."
    
    if timeout 5 ssh -o ConnectTimeout=5 \
                     -o PubkeyAuthentication=yes \
                     -o PasswordAuthentication=no \
                     -o StrictHostKeyChecking=no \
                     "$test_user@$test_host" -p "$test_port" "echo 'Connection successful'" 2>/dev/null; then
        print_success "连接测试成功"
    else
        print_warning "连接失败，请检查以下内容:"
        echo "  1. 确保SSH服务已启动"
        echo "  2. 确保网络连接正常"
        echo "  3. 确保公钥已添加到远程服务器的authorized_keys"
        echo "  4. 检查防火墙设置"
    fi
}

################################################################################
#                          交互式菜单                                          #
################################################################################

# 显示主菜单
show_main_menu() {
    clear
    echo -e "\n${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                        ║${NC}"
    echo -e "${BLUE}║          SSH 管理工具套件 - 综合版本 v2.0               ║${NC}"
    echo -e "${BLUE}║                                                        ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "${CYAN}========== SSH 服务管理 ==========${NC}"
    echo "  1) 安装和启动 SSH 服务"
    echo "  2) 配置 SSH 服务"
    echo "  3) 重启 SSH 服务"
    
    echo -e "\n${CYAN}========== SSH 密钥生成 ==========${NC}"
    echo "  4) 生成 RSA 2048位密钥"
    echo "  5) 生成 RSA 4096位密钥"
    echo "  6) 生成 Ed25519 密钥"
    
    echo -e "\n${CYAN}========== SSH 密钥管理 ==========${NC}"
    echo "  7) 删除现有密钥"
    echo "  8) 删除并重新生成密钥"
    echo "  9) 备份 SSH 密钥"
    echo " 10) 恢复 SSH 密钥"
    
    echo -e "\n${CYAN}========== 公钥认证管理 ==========${NC}"
    echo " 11) 配置公钥认证"
    echo " 12) 添加远程公钥"
    echo " 13) 查看授权密钥"
    echo " 14) 删除授权密钥"
    
    echo -e "\n${CYAN}========== 信息查看 ==========${NC}"
    echo " 15) 显示密钥信息"
    echo " 16) 显示密钥文件内容"
    echo " 17) 验证密钥对"
    
    echo -e "\n${CYAN}========== 其他功能 ==========${NC}"
    echo " 18) 测试 SSH 连接"
    echo " 19) 显示安全提示"
    echo " 20) 查看日志"
    
    echo -e "\n  0) 退出脚本\n"
    
    read -p "请选择操作 (0-20): " choice
    echo ""
}

# 显示帮助信息
show_help() {
    cat << EOF

${BLUE}SSH 管理工具套件 - 使用说明${NC}

使用法:
    $0 [选项]

选项:
    -h, --help              显示此帮助信息
    -i, --install           自动安装SSH服务
    -g, --generate          生成SSH密钥（4096位RSA）
    -c, --configure         配置SSH服务
    -r, --restore           恢复SSH密钥
    -d, --delete-keys       删除SSH密钥
    -v, --verify            验证SSH密钥
    -t, --test              测试SSH连接
    -i, --info              显示SSH密钥信息
    -m, --menu              启动交互式菜单（默认）

示例:
    $0                      # 启动交互式菜单
    $0 -i                   # 安装SSH服务
    $0 -g                   # 生成密钥
    $0 -c                   # 配置服务

${YELLOW}注意:${NC}
    某些操作需要 sudo 权限
    密钥文件存储在 ~/.ssh 目录
    备份文件存储在 ~/.ssh/backup 目录

EOF
}

################################################################################
#                          主程序流程                                           #
################################################################################

# 处理命令行参数
process_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -i|--install)
                install_ssh
                exit $?
                ;;
            -g|--generate)
                generate_ssh_keys "rsa" "4096"
                exit $?
                ;;
            -c|--configure)
                configure_ssh_service
                exit $?
                ;;
            -r|--restore)
                restore_ssh_keys
                exit $?
                ;;
            -d|--delete-keys)
                delete_ssh_keys
                exit $?
                ;;
            -v|--verify)
                verify_key_pair
                exit $?
                ;;
            -t|--test)
                test_ssh_connection
                exit $?
                ;;
            -I|--info)
                display_key_info
                exit $?
                ;;
            -m|--menu)
                # 启动菜单模式
                break
                ;;
            *)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

# 主循环
main_loop() {
    while true; do
        show_main_menu
        
        case $choice in
            1) install_ssh ;;
            2) configure_ssh_service ;;
            3) restart_ssh_service ;;
            4) generate_ssh_keys "rsa" "2048" ;;
            5) generate_ssh_keys "rsa" "4096" ;;
            6) generate_ssh_keys "ed25519" "256" ;;
            7) delete_ssh_keys ;;
            8) delete_and_regenerate_ssh ;;
            9) backup_ssh_keys ;;
            10) restore_ssh_keys ;;
            11) setup_public_key_authentication ;;
            12) add_remote_public_key ;;
            13) view_authorized_keys ;;
            14) remove_authorized_key ;;
            15) display_key_info ;;
            16) display_key_contents ;;
            17) verify_key_pair ;;
            18) test_ssh_connection ;;
            19) display_security_warning ;;
            20)
                if [[ -r "$LOG_FILE" ]]; then
                    less "$LOG_FILE"
                else
                    print_warning "日志文件不可读或不存在"
                fi
                ;;
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

# 脚本入口
main() {
    # 初始化
    detect_system || exit 1
    check_permissions
    initialize_directories
    
    # 处理命令行参数
    if [[ $# -gt 0 ]]; then
        process_arguments "$@"
    fi
    
    # 启动主循环
    main_loop
}

# 执行主程序
main "$@"