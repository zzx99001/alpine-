curl -fsSL -o /tmp/xrayInStart.sh https://github.com/zzx99001/alpine-/raw/refs/heads/main/XrayInstart.sh && bash /tmp/xrayInStart.sh -p 45673 -d 'www.lacity.gov:443' -s 'lacity.gov,www.lacity.gov' && rm -f /tmp/xrayInStart.sh
# 安装 dos2unix 工具
apk add dos2unix 2>/dev/null || apt-get install -y dos2unix 2>/dev/null || yum install -y dos2unix 2>/dev/null || true

# 转换脚本文件
dos2unix /tmp/xrayInStart.sh 2>/dev/null || sed -i 's/\r$//' /tmp/xrayInStart.sh

# 再次执行脚本
bash /tmp/xrayInStart.sh -p 45673 -d 'www.lacity.gov:443' -s 'lacity.gov,www.lacity.gov'


根据您的情况，云服务器控制台没有安全组/防火墙面板，可能是因为您使用的是VPS或独立服务器，而非主流云服务商（如阿里云、腾讯云等）的云服务器。这类服务器通常只在操作系统内部进行端口控制
# 检查服务状态
rc-service xray status

# 检查端口是否被监听
ss -tlnp | grep 45673
apk add iptables
# 开放TCP端口
iptables -A INPUT -p tcp --dport 45673 -j ACCEPT

# 如果需要，也可以开放UDP端口
iptables -A INPUT -p udp --dport 45673 -j ACCEPT
# 保存规则到文件
iptables-save > /etc/iptables/rules.v4

# 创建规则目录（如果不存在）
mkdir -p /etc/iptables
# 创建启动脚本
cat > /etc/init.d/iptables << 'EOF'
#!/sbin/openrc-run

depend() {
    need net
}

start() {
    ebegin "Starting iptables"
    if [ -f /etc/iptables/rules.v4 ]; then
        iptables-restore < /etc/iptables/rules.v4
    fi
    eend $?
}

stop() {
    ebegin "Stopping iptables"
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    eend $?
}

status() {
    ebegin "iptables rules:"
    iptables -L -n -v
    eend $?
}
EOF

# 设置执行权限
chmod +x /etc/init.d/iptables

# 启用服务
rc-update add iptables default
rc-service iptables start
# 检查防火墙规则是否生效
iptables -L -n

# 从服务器内部测试端口
telnet localhost 45673

