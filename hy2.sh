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

log_info "开始安装 Hysteria2 (安全优化版)"

# 安装必要软件
log_info "安装系统依赖..."
apk update && apk add wget openssl

# 生成随机密码
generate_password() {
    dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '/+=' | cut -c1-16
}

MAIN_PASS=$(generate_password)
OBFS_PASS=$(generate_password)

# 安全的IP获取函数
get_server_ip() {
    local ip=""
    # 尝试多个IP查询服务
    local services=(
        "ipinfo.io/ip"
        "api.ipify.org"
        "icanhazip.com"
        "ident.me"
        "checkip.amazonaws.com"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -s -4 --connect-timeout 5 "$service" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    
    echo "请手动查询服务器IP"
}

SERVER_IP=$(get_server_ip)

# 配置BBR
configure_bbr() {
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
        log_info "BBR 已启用"
        return 0
    fi
    
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.somaxconn = 1024
EOF

    sysctl -p >/dev/null 2>&1 && log_info "BBR 配置完成"
}

configure_bbr

# 创建目录结构
log_info "创建目录结构..."
mkdir -p /etc/hysteria /var/log/hysteria

# 生成证书
log_info "生成TLS证书..."
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=www.bing.com" -days 36500 >/dev/null 2>&1

chmod 600 /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt

# 写入配置文件
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

# 内存优化QUIC配置
quic:
  initStreamReceiveWindow: 16777216    # 16MB - 内存优化
  maxStreamReceiveWindow: 16777216     # 16MB
  initConnReceiveWindow: 33554432      # 32MB - 内存优化
  maxConnReceiveWindow: 33554432       # 32MB
  maxIdleTimeout: 30s                  # 缩短超时释放内存
  keepAlivePeriod: 15s

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
        ;;
    aarch64) 
        URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm64"
        ;;
    armv7l) 
        URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm"
        ;;
    *) log_error "不支持的架构: $ARCH"; exit 1 ;;
esac

log_info "下载 Hysteria2 ($ARCH)..."
if ! wget -q -O /usr/local/bin/hysteria "$URL" --no-check-certificate; then
    log_error "下载失败，请检查网络连接"
    exit 1
fi

# 二进制文件完整性验证
if [ ! -f /usr/local/bin/hysteria ]; then
    log_error "下载失败：文件不存在"
    exit 1
fi

FILE_SIZE=$(stat -c%s /usr/local/bin/hysteria 2>/dev/null || wc -c < /usr/local/bin/hysteria)
if [ "$FILE_SIZE" -lt 5000000 ]; then
    log_error "文件大小异常，可能下载损坏: ${FILE_SIZE}字节"
    rm -f /usr/local/bin/hysteria
    exit 1
fi

chmod +x /usr/local/bin/hysteria

# 基本功能测试
if ! /usr/local/bin/hysteria version >/dev/null 2>&1; then
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
    rotate 3
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

sleep 5

# 验证安装
if ps aux | grep -v grep | grep -q hysteria; then
    log_info "✅ 服务运行正常"
    
    if netstat -tulpn 2>/dev/null | grep -q 40443; then
        log_info "✅ 端口监听正常"
    else
        log_warn "⚠️ 端口未检测到，但进程运行中"
    fi
else
    log_error "❌ 服务启动失败"
    log_info "请检查: tail -f /var/log/hysteria/error.log"
    exit 1
fi

# 生成正确的v2rayN链接
generate_v2rayn_link() {
    echo "hysteria2://${MAIN_PASS}@${SERVER_IP}:40443?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2"
}

# 显示配置信息
echo
echo "================================================================================"
log_info "🎉 Hysteria2 安装完成！"
echo
echo -e "${BLUE}服务器信息：${NC}"
echo "  IP地址: $SERVER_IP"
echo "  端口: 40443"
echo "  密码: $MAIN_PASS"
echo "  混淆密码: $OBFS_PASS"
echo "  SNI: www.bing.com"
echo
echo -e "${BLUE}v2rayN 一键导入链接：${NC}"
V2RAY_LINK=$(generate_v2rayn_link)
echo "$V2RAY_LINK"
echo
echo -e "${BLUE}使用方法：${NC}"
echo "  1. 复制上面的链接"
echo "  2. 在v2rayN中: 服务器 → 从剪贴板导入URL"
echo "  3. 或: 主界面右键 → 从剪贴板导入URL"
echo
echo -e "${BLUE}配置优化：${NC}"
echo "  QUIC窗口: 16MB/32MB (内存优化)"
echo "  带宽限制: 200Mbps下载/50Mbps上传"
echo "  BBR拥塞控制: 已启用"
echo "  混淆隐藏: salamander (已启用)"
echo
echo -e "${BLUE}服务管理：${NC}"
echo "  启动: rc-service hysteria start"
echo "  停止: rc-service hysteria stop" 
echo "  重启: rc-service hysteria restart"
echo "  状态: rc-service hysteria status"
echo "================================================================================"

# 保存配置到文件
log_info "保存配置信息..."
cat > /root/hysteria-config.txt << EOF
Hysteria2 服务器配置
安装时间: $(date)
服务器IP: $SERVER_IP
端口: 40443
认证密码: $MAIN_PASS
混淆密码: $OBFS_PASS
TLS SNI: www.bing.com

v2rayN 一键导入链接:
$(generate_v2rayn_link)

注意：如果IP显示"请手动查询服务器IP"，请运行以下命令获取IP：
curl -s ipinfo.io/ip
或
curl -s api.ipify.org
EOF

log_info "配置已保存到: /root/hysteria-config.txt"
log_info "安装完成！"

# 如果IP获取失败，提示用户
if [ "$SERVER_IP" = "请手动查询服务器IP" ]; then
    echo
    log_warn "⚠️  无法自动获取服务器IP，请手动查询："
    echo "  运行: curl -s ipinfo.io/ip"
    echo "  或: curl -s api.ipify.org"
    echo "  然后将IP填入客户端配置中"
fi
