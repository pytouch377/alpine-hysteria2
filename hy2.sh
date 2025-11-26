#!/bin/bash

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

set -e

log_info "开始安装 Hysteria2 (精简优化版)"

# 安装必要软件
log_info "安装系统依赖..."
apk update && apk add wget openssl

# 生成随机密码
generate_password() {
    dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '/+=' | cut -c1-16
}

MAIN_PASS=$(generate_password)
OBFS_PASS=$(generate_password)

# 配置BBR
configure_bbr() {
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
        log_info "BBR 已启用"
        return 0
    fi
    
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.somaxconn = 1024
EOF

    sysctl -p >/dev/null 2>&1 && log_info "BBR 配置完成"
}

configure_bbr

# Hysteria2配置
cat > /etc/hysteria/config.yaml << EOF
listen: :40443

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: $MAIN_PASS

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS

quic:
  initStreamReceiveWindow: 33554432
  maxStreamReceiveWindow: 33554432
  initConnReceiveWindow: 67108864
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 60s

ignoreClientBandwidth: true

bandwidth:
  up: 200 mbps
  down: 50 mbps

masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

resolver:
  type: udp
  udp:
    addr: 8.8.8.8:53

log:
  level: info
EOF

# 服务文件
cat > /etc/init.d/hysteria << 'EOF'
#!/sbin/openrc-run

name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background=true
pidfile="/var/run/hysteria.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log/hysteria 2>/dev/null || mkdir -p /var/log/hysteria
}
EOF

# 根据架构下载
ARCH=$(uname -m)
case $ARCH in
    x86_64) URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64" ;;
    aarch64) URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm64" ;;
    armv7l) URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm" ;;
    *) log_error "不支持的架构: $ARCH"; exit 1 ;;
esac

log_info "下载 Hysteria2..."
wget -q -O /usr/local/bin/hysteria "$URL" --no-check-certificate
chmod +x /usr/local/bin/hysteria

# 创建目录和证书
mkdir -p /etc/hysteria /var/log/hysteria

openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=www.bing.com" -days 36500 >/dev/null 2>&1

chmod 600 /etc/hysteria/server.key

# 配置日志轮转
cat > /etc/logrotate.d/hysteria << 'EOF'
/var/log/hysteria/*.log {
    daily
    missingok
    rotate 3
    compress
    notifempty
    copytruncate
    maxsize 2M
}
EOF

# 启动服务
chmod +x /etc/init.d/hysteria
pkill hysteria 2>/dev/null || true
sleep 2

rc-update add hysteria default 2>/dev/null || true
/etc/init.d/hysteria start

sleep 3

# 验证安装
if ps aux | grep -v grep | grep -q hysteria; then
    log_info "✅ 服务运行正常"
else
    log_error "❌ 服务启动失败"
    exit 1
fi

# 显示配置信息
echo
echo "================================================================================"
log_info "🎉 Hysteria2 安装完成！"
echo
echo -e "${BLUE}连接信息：${NC}"
echo "  服务器: 你的服务器IP:40443"
echo "  密码: $MAIN_PASS"
echo "  混淆密码: $OBFS_PASS"
echo "  SNI: www.bing.com"
echo
echo -e "${BLUE}v2rayN 一键导入：${NC}"
echo "hysteria2://${MAIN_PASS}@你的服务器IP:40443/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2"
echo
echo -e "${BLUE}服务管理：${NC}"
echo "  rc-service hysteria start|stop|restart|status"
echo "================================================================================"

# 保存配置
cat > /root/hysteria-config.txt << EOF
Hysteria2 配置信息
服务器: 你的服务器IP:40443
密码: $MAIN_PASS
混淆密码: $OBFS_PASS
SNI: www.bing.com

v2rayN链接:
hysteria2://${MAIN_PASS}@你的服务器IP:40443/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2
EOF

log_info "配置已保存到: /root/hysteria-config.txt"