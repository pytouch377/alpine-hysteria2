#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }

# 错误处理
set -e

log_info "开始安装 Hysteria2 (个人使用优化版)"

# 安装必要软件（最小化）
log_info "安装系统依赖..."
apk update
apk add wget openssl

# 生成随机密码
generate_random_password() {
  dd if=/dev/urandom bs=18 count=1 status=none | base64 | tr -d '/+=' | cut -c1-16
}

GENPASS="$(generate_random_password)"
log_debug "生成连接密码: $GENPASS"

# 个人使用优化配置
echo_hysteria_config_yaml() {
  cat << EOF
listen: :40443

# 使用自签名证书
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

# 认证配置
auth:
  type: password
  password: $GENPASS

# 个人使用优化的QUIC配置 (200Mbps性能优化)
quic:
  initStreamReceiveWindow: 33554432    # 32MB - 充分发挥200M性能
  maxStreamReceiveWindow: 33554432
  initConnReceiveWindow: 67108864      # 64MB - 为突发流量准备
  maxConnReceiveWindow: 67108864
  maxIdleTimeout: 60s                  # 延长超时避免频繁重连
  keepAlivePeriod: 20s
  maxIncomingStreams: 512              # 个人使用512足够

# 禁用客户端带宽欺骗 (节省内存)
ignoreClientBandwidth: true

# 带宽限制到200M (适配300M宽带)
bandwidth:
  up: 200 mbps      # 对应客户端的下载，限制到200Mbps
  down: 100 mbps    # 对应客户端的上传，限制到100Mbps

# 传输优化
transport:
  udp:
    hopInterval: 30s

# 伪装配置
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true

# DNS解析配置
resolver:
  type: udp
  udp:
    addr: 8.8.8.8:53
    timeout: 3s

# 日志配置 (info级别方便个人用户排查问题)
log:
  level: info
  timestamp: true
EOF
}

# 个人使用服务配置 (无内存限制，让系统自动管理)
echo_hysteria_autoStart(){
  cat << 'EOF'
#!/sbin/openrc-run

name="hysteria"
description="Hysteria2 Proxy Server (Personal Use Optimized)"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background="yes"
pidfile="/var/run/hysteria.pid"
output_log="/var/log/hysteria/output.log"
error_log="/var/log/hysteria/error.log"

# 个人使用无需严格内存限制，系统自动管理更高效
depend() {
    need net
    after firewall
}

start_pre() {
    # 创建日志目录
    checkpath --directory --mode 0755 /var/log/hysteria 2>/dev/null || mkdir -p /var/log/hysteria
    
    # 预检查配置
    if [ -x "/usr/local/bin/hysteria" ]; then
    fi
}

start_post() {
    sleep 3
    if [ -f "/var/run/hysteria.pid" ] && kill -0 $(cat /var/run/hysteria.pid) 2>/dev/null; then
        echo "Hysteria2 启动成功 (个人使用优化版)"
    else
        echo "Hysteria2 启动可能失败，请检查日志"
        return 1
    fi
}

stop_post() {
    [ -f "/var/run/hysteria.pid" ] && rm -f /var/run/hysteria.pid
    return 0
}
EOF
}

# 根据架构选择二进制文件
log_info "检测系统架构..."
ARCH=$(uname -m)
case $ARCH in
    x86_64) 
        HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-amd64"
        ARCH_NAME="amd64"
        ;;
    aarch64)
        HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm64"
        ARCH_NAME="arm64"
        ;;
    armv7l)
        HY_URL="https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-arm"
        ARCH_NAME="armv7"
        ;;
    *)
        log_error "不支持的架构: $ARCH"
        exit 1
        ;;
esac

log_info "架构: $ARCH_NAME, 下载 Hysteria2..."
wget -O /usr/local/bin/hysteria "$HY_URL" --no-check-certificate --progress=bar:force 2>&1 | tail -f -n +2

if [ ! -f /usr/local/bin/hysteria ]; then
    log_error "下载失败，请检查网络连接"
    exit 1
fi

chmod +x /usr/local/bin/hysteria
log_info "Hysteria2 下载完成"

# 创建配置目录
log_info "创建配置目录..."
mkdir -p /etc/hysteria/
mkdir -p /var/log/hysteria

# 生成证书
log_info "生成TLS证书..."
openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=www.bing.com" \
    -days 36500

# 设置证书权限
chmod 600 /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt
log_info "TLS证书生成完成"

# 写入配置文件
log_info "生成配置文件..."
echo_hysteria_config_yaml > /etc/hysteria/config.yaml

# 写入服务文件
log_info "配置系统服务..."
echo_hysteria_autoStart > /etc/init.d/hysteria
chmod +x /etc/init.d/hysteria

# 停止可能运行的实例
log_info "停止现有服务..."
pkill hysteria 2>/dev/null || true
sleep 2

# 启用并启动服务
log_info "启动Hysteria2服务..."
rc-update add hysteria default 2>/dev/null || log_warn "服务添加自启动失败，但继续安装"

/etc/init.d/hysteria start

# 等待并检查状态
log_info "等待服务启动..."
sleep 5

# 验证服务状态
log_info "验证服务状态..."
if netstat -tulpn 2>/dev/null | grep -q 40443; then
    log_info "✅ 服务端口监听成功"
else
    log_warn "⚠️  服务端口未检测到，但进程可能仍在运行"
fi

if ps aux | grep -v grep | grep -q hysteria; then
    log_info "✅ 服务进程运行正常"
    HY_PID=$(ps aux | grep -v grep | grep hysteria | awk '{print $2}')
    log_debug "服务PID: $HY_PID"
else
    log_error "❌ 服务进程未运行"
    log_info "请检查日志: tail -f /var/log/hysteria/error.log"
    exit 1
fi

# 显示安装结果
echo
echo "================================================================================"
log_info "🎉 Hysteria2 安装完成！"
echo
echo "📡 连接信息："
echo "  服务器: 你的服务器IP:40443"
echo "  密码: $GENPASS"
echo "  TLS SNI: www.bing.com"
echo "  协议: Hysteria2"
echo
echo "📁 文件位置："
echo "  配置文件: /etc/hysteria/config.yaml"
echo "  证书文件: /etc/hysteria/server.crt"  
echo "  私钥文件: /etc/hysteria/server.key"
echo "  日志文件: /var/log/hysteria/"
echo
echo "⚙️  服务管理："
echo "  启动: rc-service hysteria start"
echo "  停止: rc-service hysteria stop"
echo "  重启: rc-service hysteria restart"
echo "  状态: rc-service hysteria status"
echo
echo "📊 性能配置："
echo "  带宽限制: 200Mbps下载 / 100Mbps上传"
echo "  内存管理: 系统自动优化 (个人使用专用)"
echo "  连接优化: 适配个人刷视频等场景"
echo
echo "🔍 监控命令："
echo "  内存使用: free -m"
echo "  服务状态: rc-service hysteria status"
echo "  实时日志: tail -f /var/log/hysteria/output.log"
echo "================================================================================"

# 显示当前内存状态
echo
log_info "当前系统内存状态："
free -m
echo
log_info "安装脚本执行完毕，建议重启服务器测试自启动功能"
log_info "重启命令: reboot"
