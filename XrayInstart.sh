# 创建并编辑脚本文件
#!/bin/sh
# ============================================================
# Xray Reality+VLESS 一键脚本 (Alpine Linux 适配版)
# 用法： sh xray_vless_alpine.sh [-p PORT] [-i IP] [-d DEST] [-s NAMES] [-close]
# 特点：reality+vless，confdir模式，端口管理，防火墙后置，二维码
# 适配：Alpine Linux 3.19，使用 apk 包管理器和 OpenRC
# ============================================================
set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
PKG_MANAGER="apk"
FW_TYPE="iptables"  # Alpine 默认使用 iptables
FW_PORT_OK=false
BBR_ENABLED=false
API_URL="https://api.ganguo168.com/serverResourcesThree/insert"
QUERY_BASE_URL="https://www.ganguo168.com/#/query-config"

XRAY_DIR="/usr/local/etc/xray"
CONF_FILE="${XRAY_DIR}/vlessConfig.json"
PORT_RECORD_FILE="/usr/local/etc/firewalld.json"
CURRENT_KEY="vlessConfig.json"

OLD_PORTS=""
PORT=""
SERVER_IP=""
DEST="lacity.gov:443"
SERVER_NAMES="lacity.gov,www.lacity.gov"
CLIENT_ID=""
PUBLIC_KEY=""
PRIVATE_KEY=""
SHORT_ID=""
PASSWORD=""
SERVER_NAMES_JSON=""
QR_ENABLED=true

# ===================== 系统识别 =====================
detect_pkg_manager() {
    if ! command -v apk >/dev/null 2>&1; then
        echo -e "${RED}[ERR]${NC} 只能在 Alpine Linux 上运行此脚本"
        exit 1
    fi
    echo -e "${BLUE}[INFO]${NC} 包管理器: $PKG_MANAGER"
}

install_if_missing() {
    local cmd="$1"
    local pkg="$2"
    
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    
    echo -e "${BLUE}[INFO]${NC} 安装 $pkg ..."
    apk add --no-cache "$pkg" 2>&1 || {
        echo -e "${YELLOW}[WARN]${NC} 包安装可能失败，继续尝试..."
    }
}

# ===================== BBR =====================
enable_bbr() {
    echo -e "${CYAN}[BBR]${NC} 检查并尝试开启 BBR ..."
    
    # Alpine Linux 内核版本检查
    local kernel_version=$(uname -r)
    local major=$(echo "$kernel_version" | cut -d. -f1)
    local minor=$(echo "$kernel_version" | cut -d. -f2)
    
    if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; }; then
        echo -e "${YELLOW}[WARN]${NC} 内核版本过低，不支持 BBR"
        BBR_ENABLED=false
        return
    fi
    
    # 检查当前拥塞控制算法
    local cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$cc" = "bbr" ]; then
        echo -e "${GREEN}[OK]${NC} BBR 已启用"
        BBR_ENABLED=true
        return
    fi
    
    # 加载 BBR 模块
    modprobe tcp_bbr 2>/dev/null || true
    
    # 配置 sysctl
    if [ -f /etc/sysctl.conf ]; then
        if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
            cat >> /etc/sysctl.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        fi
    fi
    
    sysctl -p 2>/dev/null || true
    
    # 验证
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
    if [ "$cc" = "bbr" ]; then
        echo -e "${GREEN}[OK]${NC} BBR 已开启"
        BBR_ENABLED=true
    else
        echo -e "${YELLOW}[WARN]${NC} BBR 开启失败，当前: $cc"
    fi
}

# ===================== 防火墙 =====================
detect_firewall() {
    # Alpine Linux 通常使用 iptables 或 nftables
    if command -v iptables >/dev/null 2>&1; then
        FW_TYPE="iptables"
    elif command -v nft >/dev/null 2>&1; then
        FW_TYPE="nftables"
    else
        FW_TYPE="none"
    fi
    echo -e "${BLUE}[INFO]${NC} 防火墙类型: $FW_TYPE"
}

close_old_port() {
    local port="$1"
    echo -e "${BLUE}[INFO]${NC} 关闭旧端口 $port ..."
    
    case "$FW_TYPE" in
        iptables)
            iptables -D INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            iptables -D INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
            ;;
        nftables)
            # nftables 规则删除需要更复杂的命令
            echo -e "${YELLOW}[WARN]${NC} 请手动清理 nftables 规则"
            ;;
        none)
            echo -e "${YELLOW}[WARN]${NC} 无防火墙，请手动处理端口 $port"
            ;;
    esac
}

open_port() {
    local port="$1"
    echo -e "${BLUE}[INFO]${NC} 开放端口 $port ..."
    
    case "$FW_TYPE" in
        iptables)
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            iptables -I INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null || true
            ;;
        nftables)
            # nftables 简单实现
            nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
            nft add rule inet filter input udp dport "$port" accept 2>/dev/null || true
            ;;
        none)
            echo -e "${YELLOW}[WARN]${NC} 无防火墙，请手动开放端口 $port"
            return 0
            ;;
    esac
    
    sleep 1
}

save_old_ports() {
    OLD_PORTS=""
    
    if [ -f "$PORT_RECORD_FILE" ]; then
        local recorded=$(grep "$CURRENT_KEY" "$PORT_RECORD_FILE" 2>/dev/null | cut -d'[' -f2 | cut -d']' -f1 | tr ',' ' ' | tr -d '"' || true)
        if [ -n "$recorded" ]; then
            OLD_PORTS="$recorded"
        fi
    fi
    
    if [ -f "$CONF_FILE" ]; then
        local cur_port=$(grep -o '"port"[[:space:]]*:[[:space:]]*[0-9]*' "$CONF_FILE" 2>/dev/null | grep -o '[0-9]*$' | head -1)
        if [ -n "$cur_port" ]; then
            OLD_PORTS="$OLD_PORTS $cur_port"
        fi
    fi
    
    OLD_PORTS=$(echo "$OLD_PORTS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
    
    if [ -n "$OLD_PORTS" ]; then
        echo -e "${BLUE}[INFO]${NC} 已记录旧端口: $OLD_PORTS"
    else
        echo -e "${BLUE}[INFO]{NC} 未发现旧端口记录"
    fi
}

finalize_firewall() {
    detect_firewall
    echo -e "${CYAN}[Firewall]${NC} 开始配置防火墙..."
    
    if [ -n "$OLD_PORTS" ]; then
        for port in $OLD_PORTS; do
            if [ "$port" != "$PORT" ]; then
                close_old_port "$port"
            fi
        done
    fi
    
    open_port "$PORT"
    echo -e "${GREEN}[OK]${NC} 防火墙规则已更新"
}

# ===================== 端口冲突检查 =====================
check_port_conflict() {
    local new_port="$1"
    local current_key="${2:-}"
    
    # 系统级检测 - Alpine 精简环境适配
    local listening_info=""
    
    # 尝试使用 ss（如果可用）
    if command -v ss >/dev/null 2>&1; then
        listening_info=$(ss -tlnp 2>/dev/null | grep ":${new_port}" || true)
    fi
    
    # 如果 ss 不可用，尝试 netstat（可能需要安装）
    if [ -z "$listening_info" ] && command -v netstat >/dev/null 2>&1; then
        listening_info=$(netstat -tlnp 2>/dev/null | grep ":${new_port}" || true)
    fi
    
    # 如果都不可用，使用 fuser（如果可用）
    if [ -z "$listening_info" ] && command -v fuser >/dev/null 2>&1; then
        listening_info=$(fuser -n tcp "$new_port" 2>&1 || true)
    fi
    
    if [ -n "$listening_info" ]; then
        echo -e "${YELLOW}[WARN]${NC} 端口 $new_port 已被系统进程占用"
        echo "$listening_info" | head -3
        
        # 简单处理：提示用户确认
        echo -e "${YELLOW}       端口被占用，请确认是否继续。${NC}"
        read -p "继续使用端口 $new_port 吗？(y/n): " choice
        if [ "$choice" != "y" ] && [ "$choice" != "Y" ]; then
            exit 1
        fi
    else
        echo -e "${GREEN}[INFO]${NC} 端口 $new_port 未被系统占用"
    fi
    
    # 配置文件级检测
    local conflict_files=""
    for f in "$XRAY_DIR"/*.json; do
        [ ! -f "$f" ] && continue
        [ "$f" = "$CONF_FILE" ] && continue
        if grep -qE "\"port\"[[:space:]]*:[[:space:]]*${new_port}" "$f" 2>/dev/null; then
            conflict_files="$conflict_files\n  - $(basename "$f")"
        fi
    done
    
    if [ -n "$conflict_files" ]; then
        echo -e "${RED}[ERR]${NC} 端口 $new_port 已被以下配置文件占用:"
        echo "$conflict_files"
        echo -e "${YELLOW}       请更换端口或先修改上述配置文件。${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}[OK]${NC} 端口 $new_port 检查通过"
}

# ===================== Xray 安装 =====================
install_xray() {
    echo -e "${CYAN}[Xray]${NC} 安装/检查 Xray ..."
    
    if command -v xray >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} 检测到 xray"
        return
    fi
    
    echo -e "${YELLOW}[WARN]${NC} 未找到 xray，通过官方脚本安装..."
    
    # 下载安装脚本
    wget -O /tmp/install-xray.sh https://github.com/XTLS/Xray-install/raw/main/alpinelinux/install-release.sh || {
        echo -e "${RED}[ERR]${NC} 下载安装脚本失败"
        exit 1
    }
    
    # 执行安装
    sh /tmp/install-xray.sh @ install || {
        echo -e "${RED}[ERR]${NC} Xray 安装失败"
        exit 1
    }
    
    # 清理安装脚本
    rm -f /tmp/install-xray.sh
    
    if ! command -v xray >/dev/null 2>&1; then
        echo -e "${RED}[ERR]${NC} 安装后仍找不到 xray 命令"
        exit 1
    fi
    
    echo -e "${GREEN}[OK]${NC} Xray 安装完成"
}
generate_keys() {
    echo -e "${CYAN}[Key]${NC} 生成 x25519 公私钥..."
    local xray_bin="xray"
    [ -x "/usr/local/bin/xray" ] && xray_bin="/usr/local/bin/xray"
    
    # 使用更稳健的方式提取：先定位行，再截取字段
    local key_output=$("$xray_bin" x25519 2>&1) || {
        echo -e "${RED}[ERR]${NC} x25519 密钥生成失败"
        exit 1
    }
    
    # 提取私钥 (取最后一行包含 Private 的内容)
    PRIVATE_KEY=$(echo "$key_output" | grep "Private" | awk '{print $NF}')
    # 提取公钥 (取最后一行包含 Public 的内容)
    PUBLIC_KEY=$(echo "$key_output" | grep "Public" | awk '{print $NF}')
    
    [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ] && {
        echo -e "${RED}[ERR]${NC} 解析公私钥失败"
        echo -e "${YELLOW}[DEBUG]${NC} 原始输出如下："
        echo "$key_output"
        exit 1
    }
    echo -e "${GREEN}[OK]${NC} Private key: $PRIVATE_KEY"
    echo -e "${GREEN}[OK]${NC} Public key:  $PUBLIC_KEY"
}
generate_clientid() {
    CLIENT_ID=""
    for i in $(seq 1 10); do
        CLIENT_ID="${CLIENT_ID}$(( RANDOM % 10 ))"
    done
    echo -e "${BLUE}[INFO]${NC} 生成 clients.id: $CLIENT_ID"
}

generate_shortid() {
    # Alpine Linux 可能没有 /dev/urandom，使用 openssl 或随机函数
    if command -v openssl >/dev/null 2>&1; then
        SHORT_ID=$(openssl rand -hex 6 2>/dev/null | head -c 12)
    else
        # 使用 ash 内置随机数
        SHORT_ID=""
        for i in $(seq 1 12); do
            SHORT_ID="${SHORT_ID}$(( RANDOM % 16 ))"
        done
    fi
    
    echo -e "${BLUE}[INFO]${NC} 生成 shortId: $SHORT_ID"
}

build_server_names_json() {
    IFS=',' read -ra NAMES <<< "$SERVER_NAMES"
    local lines=()
    for name in "${NAMES[@]}"; do
        name=$(echo "$name" | xargs)
        [ -n "$name" ] && lines+=("            \"$name\"")
    done
    
    local last_idx=$((${#lines[@]} - 1))
    for i in "${!lines[@]}"; do
        if [ "$i" -lt "$last_idx" ]; then
            echo "${lines[$i]},"
        else
            echo "${lines[$i]}"
        fi
    done
}

write_config() {
    echo -e "${BLUE}[INFO]${NC} 写入配置文件..."
    
    mkdir -p "$XRAY_DIR"
    check_port_conflict "$PORT" "$CURRENT_KEY"
    
    SERVER_NAMES_JSON=$(build_server_names_json)
    
    cat > "$CONF_FILE" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${CLIENT_ID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [
${SERVER_NAMES_JSON}
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ],
          "fingerprint": "chrome"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      },
      "tag": "inbound-${PORT}"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": []
  }
}
EOF
    
    echo -e "${GREEN}[OK]${NC} 配置文件 $CONF_FILE 已写入"
}

update_port_record() {
    local key="$CURRENT_KEY"
    local port=$PORT
    
    # Alpine Linux 简化处理，直接写入 JSON
    cat > "$PORT_RECORD_FILE" << EOF
{
  "$key": [$PORT]
}
EOF
    
    echo -e "${GREEN}[OK]${NC} 端口记录已更新"
}

# ===================== 重启 Xray（OpenRC 适配） =====================
restart_xray() {
    echo -e "${CYAN}[Xray]${NC} 启动/重启 Xray 服务（OpenRC 模式）..."
    
    local xray_bin="xray"
    [ -x "/usr/local/bin/xray" ] && xray_bin="/usr/local/bin/xray"
    
    # 检查是否已存在服务
    if rc-service --exists xray 2>/dev/null; then
        echo -e "${BLUE}[INFO]${NC} 检测到 Xray 服务，正在重启..."
        
        # 停止服务
        rc-service xray stop 2>/dev/null || true
        
        # 启动服务
        rc-service xray start || {
            echo -e "${RED}[ERR]${NC} Xray 服务启动失败"
            exit 1
        }
        
        # 设置开机自启
        rc-update add xray default 2>/dev/null || true
        
        echo -e "${GREEN}[OK]${NC} Xray 服务已重启"
    else
        echo -e "${YELLOW}[WARN]${NC} 未检测到 Xray 服务，手动启动..."
        
        # 停止可能存在的旧进程
        pkill -f "xray.*-confdir.*${XRAY_DIR}" 2>/dev/null || true
        
        # 创建日志目录
        mkdir -p /var/log
        touch /var/log/xray.log
        
        # 后台启动
        nohup "$xray_bin" -confdir "$XRAY_DIR" >> /var/log/xray.log 2>&1 &
        local xray_pid=$!
        
        sleep 2
        
        if kill -0 "$xray_pid" 2>/dev/null; then
            echo -e "${GREEN}[OK]${NC} Xray 进程已启动（PID: $xray_pid）"
        else
            echo -e "${RED}[ERR]${NC} Xray 启动失败，请检查日志"
            exit 1
        fi
    fi
}

# ===================== 上报与输出 =====================
upload_config() {
    local ip=$SERVER_IP
    [ -z "$ip" ] && ip=$(wget -qO- --timeout=5 ifconfig.me 2>/dev/null || echo "0.0.0.0")
    
    echo -e "${BLUE}[INFO]${NC} 上报配置到 API..."
    
    local request_body=$(cat << EOF
{
  "resourcesIp": "${ip}",
  "publicBrokerKey": "${PUBLIC_KEY}",
  "sni": "${SERVER_NAMES}",
  "shortId": "${SHORT_ID}",
  "userId": "${CLIENT_ID}",
  "nodePort": "${PORT}"
}
EOF
)
    
    local response=$(wget -qO- --timeout=30 --header="Content-Type: application/json" \
        --post-data="$request_body" "$API_URL" 2>&1) || {
        echo -e "${RED}[ERR]${NC} API 请求失败"; return 1
    }
    
    # 简单解析响应
    PASSWORD=$(echo "$response" | grep -o '"message"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"message"[[:space:]]*:[[:space:]]*"//;s/"$//')
    
    [ -z "$PASSWORD" ] && { echo -e "${RED}[ERR]${NC} 解析密码失败"; return 1; }
    
    echo -e "${GREEN}[OK]${NC} 上报成功: ${QUERY_BASE_URL}/${PASSWORD}"
    return 0
}

print_qrcode() {
    local url="$1"
    
    if command -v qrencode >/dev/null 2>&1; then
        echo -e "  ${CYAN}请用微信扫码后在浏览器中打开查询链接信息${NC}"
        qrencode -t ANSIUTF8 -m 1 -s 2 "$url" 2>/dev/null | while IFS= read -r line; do
            echo "  $line"
        done
    else
        echo -e "${YELLOW}[WARN]${NC} qrencode 未安装，无法显示二维码"
    fi
}

print_result() {
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    VLESS+Reality 一键部署完成 (Alpine)     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  服务器 IP : ${CYAN}${SERVER_IP}${NC}"
    echo -e "  端口      : ${CYAN}${PORT}${NC}"
    echo -e "  协议      : vless + reality + tcp"
    echo -e "  回落目标  : ${CYAN}${DEST}${NC}"
    echo -e "  服务域名  : ${CYAN}${SERVER_NAMES}${NC}"
    echo -e "  Client ID : ${CYAN}${CLIENT_ID}${NC}"
    echo -e "  公钥      : ${CYAN}${PUBLIC_KEY}${NC}"
    echo -e "  短ID      : ${CYAN}${SHORT_ID}${NC}"
    echo -e "  防火墙    : ${FW_TYPE}"
    
    if [ -n "$PASSWORD" ]; then
        local full_url="${QUERY_BASE_URL}/${PASSWORD}"
        echo -e "  查询链接  : ${CYAN}${full_url}${NC}"
        
        if [ "$QR_ENABLED" = "true" ]; then
            echo ""
            print_qrcode "$full_url"
        fi
    else
        echo -e "  ${RED}上报失败，未获取查询链接${NC}"
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
}

usage() {
    echo "用法: $0 [选项]"
    echo "  -p, --port PORT           监听端口 (必填, 1-65535)"
    echo "  -i, --ip IP               服务器公网IP"
    echo "  -d, --dest DEST           回落目标 (默认: lacity.gov:443)"
    echo "  -s, --server-names NAMES  域名, 逗号分隔"
    echo "  -close                    关闭二维码显示"
    echo "  -h, --help                显示帮助"
    exit 0
}

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -p|--port)           PORT="$2"; shift 2 ;;
            -i|--ip)             SERVER_IP="$2"; shift 2 ;;
            -d|--dest)           DEST="$2"; shift 2 ;;
            -s|--server-names)   SERVER_NAMES="$2"; shift 2 ;;
            -close)              QR_ENABLED=false; shift ;;
            -h|--help)           usage ;;
            *) echo -e "${RED}[ERR]${NC} 未知参数: $1"; usage ;;
        esac
    done

    [ -z "$PORT" ] && { echo -e "${RED}[ERR]${NC} 必须指定端口号"; usage; }
    
    # 端口范围验证（Alpine 的 sh 不支持 [[ ]] 语法）
    case "$PORT" in
        ''|*[!0-9]*) 
            echo -e "${RED}[ERR]${NC} 端口号必须是 1-65535 之间的整数"
            exit 1
            ;;
    esac
    
    [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ] && {
        echo -e "${RED}[ERR]${NC} 端口号必须在 1-65535 之间"
        exit 1
    }

    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║    Xray Reality+VLESS 一键脚本             ║${NC}"
    echo -e "${BLUE}║    适配 Alpine Linux 3.19                  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
    echo ""

    detect_pkg_manager
    install_if_missing "curl" "curl"
    install_if_missing "wget" "wget"
    install_if_missing "ss" "iproute2"
    install_if_missing "openssl" "openssl"
    [ "$QR_ENABLED" = "true" ] && install_if_missing "qrencode" "qrencode" || true

    if [ -z "$SERVER_IP" ]; then
        echo -e "${BLUE}[INFO]${NC} 未指定IP，自动检测公网IP..."
        SERVER_IP=$(wget -qO- --timeout=5 ifconfig.me 2>/dev/null || echo "0.0.0.0")
        [ "$SERVER_IP" = "0.0.0.0" ] && { 
            echo -e "${RED}[ERR]${NC} 自动检测IP失败，请用 -i 指定"
            exit 1
        }
    fi
    echo -e "${BLUE}[INFO]${NC} 服务器IP: $SERVER_IP"

    enable_bbr
    install_xray
    generate_keys
    generate_clientid
    generate_shortid
    save_old_ports
    write_config
    update_port_record
    restart_xray
    finalize_firewall
    upload_config || true
    print_result
}
main "$@"

