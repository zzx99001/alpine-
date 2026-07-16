curl -fsSL -o /tmp/xrayInStart.sh https://github.com/zzx99001/alpine-/raw/refs/heads/main/XrayInstart.sh && bash /tmp/xrayInStart.sh -p 45673 -d 'www.lacity.gov:443' -s 'lacity.gov,www.lacity.gov' && rm -f /tmp/xrayInStart.sh
# 安装 dos2unix 工具
apk add dos2unix 2>/dev/null || apt-get install -y dos2unix 2>/dev/null || yum install -y dos2unix 2>/dev/null || true

# 转换脚本文件
dos2unix /tmp/xrayInStart.sh 2>/dev/null || sed -i 's/\r$//' /tmp/xrayInStart.sh

# 再次执行脚本
bash /tmp/xrayInStart.sh -p 45673 -d 'www.lacity.gov:443' -s 'lacity.gov,www.lacity.gov'



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

请在脚本中找到 "port": ${PORT}, 这一行（大约在函数的第 12 行）。
    
    echo -e "${GREEN}[OK]${NC} 配置文件 $CONF_FILE 已写入"
