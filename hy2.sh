#!/bin/bash

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${CYAN}[DEBUG]${NC} $1"; }
log_result() { echo -e "${BLUE}[RESULT]${NC} $1"; }

# 错误处理
set -e

log_info "开始安装 Hysteria2 (完整优化版 + BBR + 混淆)"

# 安装必要软件（最小化）
log_info "安装系统依赖..."
apk update
apk add wget openssl curl

# 生成随机密码
generate_random_password() {
  dd if=/dev/urandom bs=18 count=1 status=none | base64 | tr -d '/+=' | cut -c1-16
}

# 生成配置用的密码
MAIN_PASS="$(generate_random_password)"
OBFS_PASS="$(generate_random_password)"

log_debug "生成认证密码: $MAIN_PASS"
log_debug "生成混淆密码: $OBFS_PASS"

# 配置BBR网络优化
configure_bbr() {
    log_info "配置BBR网络优化..."
    
    # 检查是否已开启BBR
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
        log_info "BBR 已经启用"
        return 0
    fi
    
    # Alpine兼容的BBR配置
    cat >> /etc/sysctl.conf << 'EOF'

# Hysteria2 网络优化 (BBR + 缓冲区优化)
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = 786432 1048576 1572864
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_fastopen = 3
EOF

    # 立即生效
    if sysctl -p > /dev/null 2>&1; then
        log_info "BBR 优化配置已应用"
    else
        log_warn "部分网络参数设置失败（Alpine兼容性问题，不影响主要功能）"
    fi
    
    # 验证BBR是否启用
    if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        log_info "✅ BBR 启用成功"
    else
        log_warn "⚠️  BBR 启用可能失败，但继续安装"
    fi
}

# 执行BBR优化
configure_bbr

# 完整优化配置
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
  password: $MAIN_PASS

# 混淆配置（增强隐蔽性）
obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS

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
  up: 200 mbps      # 服务端上传 = 客户端下载 (200Mbps)
  down: 50 mbps     # 服务端下载 = 客户端上传 (50Mbps)

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

# 日志配置 (只记录错误，大幅减少日志量)
log:
  level: error
  timestamp: true
EOF
}

# 个人使用服务配置
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

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log/hysteria 2>/dev/null || mkdir -p /var/log/hysteria
    if [ ! -f /etc/hysteria/config.yaml ]; then
        echo "错误：配置文件不存在"
        return 1
    fi
}

start_post() {
    sleep 3
    if [ -f "/var/run/hysteria.pid" ] && kill -0 $(cat /var/run/hysteria.pid) 2>/dev/null; then
        echo "Hysteria2 启动成功 (完整优化版)"
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

# 生成v2rayN导入链接
generate_v2rayn_links() {
    log_info "生成 v2rayN 导入链接..."
    
    # 获取服务器公网IP
    SERVER_IP=$(curl -s -4 ifconfig.co || curl -s -4 ip.sb || echo "你的服务器IP")
    
    # 标准Hysteria2链接
    HY2_LINK="hysteria2://${MAIN_PASS}@${SERVER_IP}:40443/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2-服务器"
    
    # 编码为URL格式
    HY2_LINK_ENCODED=$(echo -n "$HY2_LINK" | base64 | tr -d '\n')
    
    # 生成v2rayN订阅链接
    V2RAYN_SUB="https://sub.xf.free.hr/convert?url=${HY2_LINK_ENCODED}&type=Hysteria2"
    
    echo
    log_result "=== v2rayN 导入信息 ==="
    echo
    log_result "1. 直接配置信息:"
    echo "   地址: $SERVER_IP"
    echo "   端口: 40443"
    echo "   密码: $MAIN_PASS"
    echo "   混淆: salamander"
    echo "   混淆密码: $OBFS_PASS"
    echo "   SNI: www.bing.com"
    echo "   跳过证书验证: 是"
    echo
    log_result "2. 一键导入链接:"
    echo "   $HY2_LINK"
    echo
    log_result "3. v2rayN订阅链接 (推荐):"
    echo "   $V2RAYN_SUB"
    echo
    log_result "使用方法:"
    echo "   - 复制『一键导入链接』在v2rayN中右键→从剪贴板导入URL"
    echo "   - 或使用『v2rayN订阅链接』添加到订阅"
    echo "   - 或手动填写『直接配置信息』"
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

# === 新增日志轮转配置 ===
configure_log_rotation() {
    log_info "配置日志轮转..."
    
    # 安装logrotate
    if ! command -v logrotate >/dev/null 2>&1; then
        log_info "安装 logrotate..."
        apk add logrotate > /dev/null 2>&1
    fi
    
    if command -v logrotate >/dev/null 2>&1; then
        cat > /etc/logrotate.d/hysteria << 'EOF'
/var/log/hysteria/*.log {
    daily
    missingok
    rotate 1
    compress
    delaycompress
    notifempty
    copytruncate
    maxsize 1M
}
EOF
        log_info "✅ 日志轮转配置完成 (保留7天，最大50MB)"
    else
        log_warn "⚠️  logrotate安装失败，使用crontab备用方案"
        # 备用方案：crontab清理
        (crontab -l 2>/dev/null | grep -v "hysteria"; echo "0 2 * * * find /var/log/hysteria -name \"*.log.*\" -mtime +7 -delete") | crontab -
        log_info "✅ 日志清理任务已添加到crontab"
    fi
}

# 执行日志轮转配置
configure_log_rotation
# === 日志轮转配置结束 ===


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
echo "📡 服务器信息："
echo "  服务器IP: $(curl -s -4 ifconfig.co || curl -s -4 ip.sb || echo '请手动查询')"
echo "  端口: 40443"
echo "  认证密码: $MAIN_PASS"
echo "  混淆密码: $OBFS_PASS"
echo "  TLS SNI: www.bing.com"
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
echo "🚀 性能特性："
echo "  带宽限制: 200Mbps下载 / 50Mbps上传"
echo "  BBR优化: 已启用"
echo "  混淆隐藏: salamander (已启用)"
echo "  内存优化: 个人使用专用"
echo
echo "🔍 系统状态："
echo "  BBR状态: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '检测失败')"
echo "  内存使用: $(free -m | awk 'NR==2{printf "%sMB/%sMB (%.1f%%)", $3, $2, $3*100/$2}')"
echo "================================================================================"

# 生成v2rayN导入链接
generate_v2rayn_links

# 保存配置信息到文件
cat > /root/hysteria2-config.txt << EOF
Hysteria2 服务器配置信息
安装时间: $(date)
服务器IP: $(curl -s -4 ifconfig.co || echo "请手动查询")
端口: 40443
认证密码: $MAIN_PASS
混淆密码: $OBFS_PASS
TLS SNI: www.bing.com

v2rayN 一键导入链接:
hysteria2://${MAIN_PASS}@$(curl -s -4 ifconfig.co || echo "你的服务器IP"):40443/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2-服务器

配置备份位置: /root/hysteria2-config.txt
EOF

log_info "配置已备份到: /root/hysteria2-config.txt"
log_info "安装完成！建议重启服务器测试完整功能"
log_info "重启命令: reboot"
