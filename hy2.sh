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

# 内存检查
check_memory() {
    TOTAL_MEM=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [ "$TOTAL_MEM" -lt 100 ]; then
        log_error "内存不足: ${TOTAL_MEM}MB < 100MB 最低要求"
        exit 1
    fi
    log_info "内存检查通过: ${TOTAL_MEM}MB"
}

check_memory
log_info "开始安装 Hysteria2 (128M优化版)"

# 安装必要软件
log_info "安装系统依赖..."
if ! apk update; then
    log_error "软件源更新失败"
    exit 1
fi

if ! apk add wget openssl curl; then
    log_error "依赖包安装失败"
    exit 1
fi

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
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 512
net.core.netdev_max_backlog = 5000
EOF

    sysctl -p >/dev/null 2>&1 && log_info "BBR 配置完成"
}

configure_bbr

# 创建目录结构（必须先创建目录！）
log_info "创建目录结构..."
mkdir -p /etc/hysteria /var/log/hysteria

# 生成证书（在目录创建后）
log_info "生成TLS证书..."
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=www.bing.com" -days 36500 >/dev/null 2>&1

chmod 600 /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt

# 写入配置文件（在目录创建后）
log_info "生成配置文件..."
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
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 16777216
  maxConnReceiveWindow: 33554432
  maxIdleTimeout: 60s
  keepAlivePeriod: 20s
  maxIncomingStreams: 128

ignoreClientBandwidth: true

bandwidth:
  up: 290 mbps
  down: 60 mbps

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
  level: error
EOF

# 服务文件
log_info "配置系统服务..."
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

chmod +x /etc/init.d/hysteria

# 根据架构下载并验证二进制文件
ARCH=$(uname -m)
case $ARCH in
    x86_64) 
        URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64"
        EXPECTED_SIZE=12000000  # 大约12MB
        ;;
    aarch64) 
        URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm64"
        EXPECTED_SIZE=11000000  # 大约11MB
        ;;
    armv7l) 
        URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm"
        EXPECTED_SIZE=10000000  # 大约10MB
        ;;
    *) log_error "不支持的架构: $ARCH"; exit 1 ;;
esac

log_info "下载 Hysteria2 ($ARCH)..."
if ! wget -q -O /usr/local/bin/hysteria "$URL" --no-check-certificate --timeout=30; then
    log_error "下载失败，请检查网络连接"
    exit 1
fi

# 二进制文件完整性验证
if [ ! -f /usr/local/bin/hysteria ]; then
    log_error "下载失败：文件不存在"
    exit 1
fi

FILE_SIZE=$(stat -c%s /usr/local/bin/hysteria 2>/dev/null || wc -c < /usr/local/bin/hysteria)
if [ "$FILE_SIZE" -lt 5000000 ]; then  # 至少5MB
    log_error "文件大小异常，可能下载损坏: ${FILE_SIZE}字节"
    rm -f /usr/local/bin/hysteria
    exit 1
fi

chmod +x /usr/local/bin/hysteria

# 基本功能测试
if ! timeout 5 /usr/local/bin/hysteria version >/dev/null 2>&1; then
    log_error "二进制文件无法执行，可能架构不匹配或文件损坏"
    rm -f /usr/local/bin/hysteria
    exit 1
fi

log_info "✅ 文件验证通过"

# 配置日志轮转
log_info "配置日志轮转..."
cat > /etc/logrotate.d/hysteria << 'EOF'
/var/log/hysteria/*.log {
    daily
    missingok
    rotate 2
    compress
    notifempty
    copytruncate
    maxsize 2M
}
EOF

# 停止现有服务并启动
log_info "启动Hysteria2服务..."
pkill hysteria 2>/dev/null || true
sleep 2

rc-update add hysteria default 2>/dev/null || log_warn "添加到自启动失败"
/etc/init.d/hysteria start

sleep 3

# 验证安装
if ps aux | grep -v grep | grep -q hysteria; then
    log_info "✅ 服务运行正常"
    
    # 测试端口监听
    if ss -tulpn 2>/dev/null | grep -q 40443 || netstat -tulpn 2>/dev/null | grep -q 40443; then
        log_info "✅ 端口监听正常"
    else
        log_warn "⚠️ 端口未检测到，但进程运行中"
    fi
else
    log_error "❌ 服务启动失败"
    log_info "请检查: tail -f /var/log/hysteria/error.log"
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
# 智能获取服务器IP（过滤HTML响应）
get_server_ip() {
    local ip
    # 尝试多个IP服务，过滤HTML响应
    for service in "api.ipify.org" "checkip.amazonaws.com" "ipinfo.io/ip" "icanhazip.com"; do
        ip=$(curl -s -4 --max-time 3 "$service" 2>/dev/null | grep -Eo '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -1)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo "你的服务器IP"
}

SERVER_IP=$(get_server_ip)
echo "hysteria2://${MAIN_PASS}@${SERVER_IP}:40443/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2-300M"
echo
echo -e "${BLUE}服务管理：${NC}"
echo "  rc-service hysteria start|stop|restart|status"
echo "================================================================================"

# 保存配置
cat > /root/hysteria-config.txt << EOF
Hysteria2 配置信息
服务器: ${SERVER_IP}:40443
密码: $MAIN_PASS
混淆密码: $OBFS_PASS
SNI: www.bing.com

v2rayN链接:
hysteria2://${MAIN_PASS}@${SERVER_IP}:40443/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2
EOF

log_info "配置已保存到: /root/hysteria-config.txt"
echo
log_info "🚀 性能优化提示:"
echo "  - QUIC窗口: 8MB-32MB (适配128M内存)"
echo "  - 带宽限制: 290M下行/60M上行 (适配300M家宽)"
echo "  - 日志级别: error (减少磁盘占用)"
echo "  - BBR缓冲区: 16MB (内存优化)"
log_info "安装完成！建议重启后测试"