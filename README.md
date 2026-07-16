curl -fsSL -o /tmp/xrayInStart.sh https://github.com/zzx99001/alpine-/raw/refs/heads/main/XrayInstart.sh && bash /tmp/xrayInStart.sh -p 22 -d 'www.lacity.gov:443' -s 'lacity.gov,www.lacity.gov' && rm -f /tmp/xrayInStart.sh
# 安装 dos2unix 工具
apk add dos2unix 2>/dev/null || apt-get install -y dos2unix 2>/dev/null || yum install -y dos2unix 2>/dev/null || true

# 转换脚本文件
dos2unix /tmp/xrayInStart.sh 2>/dev/null || sed -i 's/\r$//' /tmp/xrayInStart.sh

# 再次执行脚本
bash /tmp/xrayInStart.sh -p 22 -d 'www.lacity.gov:443' -s 'lacity.gov,www.lacity.gov'



