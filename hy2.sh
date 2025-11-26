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

if ! apk add wget openssl curl cpulimit; then
    log_error "依赖包安装失败"
    exit 1
fi

# 生成随机密码
generate_password() {
    dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '/+=' | cut -c1-16
}

MAIN_PASS=$(generate_password)
OBFS_PASS=$(generate_password)

# 端口选择
select_port() {
    echo
    echo -e "${BLUE}端口配置：${NC}"
    echo "请输入端口 (30000-60000)，直接回车随机生成:"
    read -p "端口: " user_port
    
    if [ -z "$user_port" ]; then
        # 随机生成端口
        PORT=$((30000 + RANDOM % 30001))
        log_info "随机生成端口: $PORT"
    elif [ "$user_port" -ge 30000 ] && [ "$user_port" -le 60000 ] 2>/dev/null; then
        PORT=$user_port
        log_info "使用指定端口: $PORT"
    else
        log_error "端口范围错误，使用随机端口"
        PORT=$((30000 + RANDOM % 30001))
        log_info "随机生成端口: $PORT"
    fi
}

select_port

# 配置BBR
configure_bbr() {
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
        log_info "BBR 已启用"
        return 0
    fi
    
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 65536 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.core.somaxconn = 256
net.core.netdev_max_backlog = 1000
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
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

# 先设置权限，等创建用户后再设置所有权
chmod 640 /etc/hysteria/server.key  # 让hysteria用户可读
chmod 644 /etc/hysteria/server.crt

# 写入配置文件（在目录创建后）
log_info "生成配置文件..."
cat > /etc/hysteria/config.yaml << EOF
listen: :$PORT

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
  initStreamReceiveWindow: 2097152
  maxStreamReceiveWindow: 4194304
  initConnReceiveWindow: 4194304
  maxConnReceiveWindow: 8388608
  maxIdleTimeout: 30s
  keepAlivePeriod: 15s
  maxIncomingStreams: 32
  disablePathMTUDiscovery: false

ignoreClientBandwidth: true

# 保守的带宽限制（防止资源耗尽）
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
  level: error
EOF

# 先设置权限，等创建用户后再设置所有权
chmod 644 /etc/hysteria/config.yaml

# 配置资源限制
log_info "配置资源限制..."
mkdir -p /etc/security/limits.d
cat > /etc/security/limits.d/hysteria.conf << 'EOF'
# Hysteria2 资源限制 (防止满载)
hysteria soft nproc 50
hysteria hard nproc 100
hysteria soft nofile 1024
hysteria hard nofile 2048
hysteria soft as 67108864  # 64MB内存限制
hysteria hard as 134217728 # 128MB内存限制
EOF

# 创建hysteria用户
if ! id hysteria >/dev/null 2>&1; then
    adduser -D -s /bin/false hysteria
    log_info "创建hysteria用户"
fi

# 现在设置文件所有权
log_info "设置文件所有权..."
chown -R hysteria:hysteria /etc/hysteria
chown hysteria:hysteria /etc/hysteria/config.yaml /etc/hysteria/server.key /etc/hysteria/server.crt

# 服务文件（带资源限制）
log_info "配置系统服务..."
cat > /etc/init.d/hysteria << 'EOF'
#!/sbin/openrc-run

name="hysteria"
command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_background=true
command_user="hysteria:hysteria"
pidfile="/var/run/hysteria.pid"

# 资源限制 (防止CPU/内存满载)
start_stop_daemon_args="--nicelevel 10"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 --owner hysteria:hysteria /var/log/hysteria 2>/dev/null || mkdir -p /var/log/hysteria
    checkpath --directory --mode 0755 --owner hysteria:hysteria /etc/hysteria
    
    # 设置资源限制 (Alpine兼容方式)
    if command -v ulimit >/dev/null 2>&1; then
        ulimit -v 131072  # 128MB虚拟内存限制
        ulimit -u 100     # 100个进程限制
        echo "资源限制已设置"
    fi
}

start_post() {
    # 应用CPU限制
    if command -v cpulimit >/dev/null 2>&1 && [ -f "$pidfile" ]; then
        sleep 1  # 等待进程启动
        PID=$(cat "$pidfile" 2>/dev/null)
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            cpulimit -p "$PID" -l 90 >/dev/null 2>&1 &
            echo "已应用90%CPU限制 (PID: $PID)"
        fi
    fi
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
    maxsize 1M
}
EOF

# 创建资源监控脚本
log_info "配置资源监控..."
cat > /usr/local/bin/hysteria-monitor << 'EOF'
#!/bin/sh
# Hysteria2 资源监控脚本

PID_FILE="/var/run/hysteria.pid"
MAX_MEM_MB=115  # 最大内存使用115MB (90% of 128MB)
MAX_CPU=90      # 最大CPU使用90%

if [ ! -f "$PID_FILE" ]; then
    exit 0
fi

PID=$(cat "$PID_FILE")
if ! kill -0 "$PID" 2>/dev/null; then
    exit 0
fi

# 检查内存使用
MEM_KB=$(ps -o rss= -p "$PID" 2>/dev/null || echo 0)
MEM_MB=$((MEM_KB / 1024))

if [ "$MEM_MB" -gt "$MAX_MEM_MB" ]; then
    echo "$(date): 内存超限 ${MEM_MB}MB > ${MAX_MEM_MB}MB, 重启服务" >> /var/log/hysteria/monitor.log
    /etc/init.d/hysteria restart
fi

# 检查CPU使用
CPU_USAGE=$(ps -o %cpu= -p "$PID" 2>/dev/null | cut -d. -f1 || echo 0)
if [ "$CPU_USAGE" -gt "$MAX_CPU" ]; then
    echo "$(date): CPU超限 ${CPU_USAGE}% > ${MAX_CPU}%, 降低优先级" >> /var/log/hysteria/monitor.log
    renice 19 "$PID" 2>/dev/null
fi
EOF

chmod +x /usr/local/bin/hysteria-monitor

# 添加定时任务
echo "*/2 * * * * /usr/local/bin/hysteria-monitor" | crontab -

# 检查端口冲突
log_info "检查端口冲突..."
if netstat -tulpn 2>/dev/null | grep -q ":$PORT " || ss -tulpn 2>/dev/null | grep -q ":$PORT "; then
    log_warn "端口 $PORT 已被占用，正在清理..."
    
    # 查找并终止占用进程
    PIDS=$(lsof -ti:$PORT 2>/dev/null || fuser $PORT/udp 2>/dev/null | awk '{print $1}')
    if [ -n "$PIDS" ]; then
        echo "$PIDS" | xargs kill -9 2>/dev/null || true
        log_info "已清理端口 $PORT 占用进程"
        sleep 2
    fi
fi

# 停止现有服务并启动
log_info "启动Hysteria2服务..."
pkill hysteria 2>/dev/null || true
sleep 2

rc-update add hysteria default 2>/dev/null || log_warn "添加到自启动失败"
/etc/init.d/hysteria start

sleep 3

# 验证安装
log_info "检查服务状态..."

# 检查服务状态
SERVICE_STATUS=$(/etc/init.d/hysteria status 2>&1)
echo "$SERVICE_STATUS"

# 检查进程
if ps aux | grep -v grep | grep -q hysteria; then
    log_info "✅ 进程运行正常"
    
    # 测试端口监听
    if ss -tulpn 2>/dev/null | grep -q $PORT || netstat -tulpn 2>/dev/null | grep -q $PORT; then
        log_info "✅ 端口监听正常"
    else
        log_warn "⚠️ 端口未检测到，但进程运行中"
    fi
else
    log_error "❌ 进程未运行"
    
    # 详细诊断
    log_info "进行详细诊断..."
    
    # 检查配置文件
    if [ -f /etc/hysteria/config.yaml ]; then
        log_info "配置文件存在"
    else
        log_error "配置文件不存在"
    fi
    
    # 检查证书文件
    if [ -f /etc/hysteria/server.crt ] && [ -f /etc/hysteria/server.key ]; then
        log_info "证书文件存在"
    else
        log_error "证书文件缺失"
    fi
    
    # 手动测试启动
    log_info "尝试手动启动..."
    chown -R hysteria:hysteria /etc/hysteria /var/log/hysteria
    
    # 直接运行测试
    echo "测试命令: sudo -u hysteria /usr/local/bin/hysteria server --config /etc/hysteria/config.yaml"
    timeout 10 sudo -u hysteria /usr/local/bin/hysteria server --config /etc/hysteria/config.yaml &
    TEST_PID=$!
    sleep 3
    
    if kill -0 $TEST_PID 2>/dev/null; then
        log_info "手动启动成功，停止测试进程"
        kill $TEST_PID 2>/dev/null
        
        # 重新启动服务
        /etc/init.d/hysteria restart
        sleep 3
        
        if ps aux | grep -v grep | grep -q hysteria; then
            log_info "✅ 服务重启成功"
        else
            log_error "服务仍无法启动"
        fi
    else
        log_error "手动启动也失败，检查配置文件"
        echo "配置文件内容:"
        head -20 /etc/hysteria/config.yaml
    fi
fi

# 显示配置信息
echo
echo "================================================================================"
log_info "🎉 Hysteria2 安装完成！"
echo
echo -e "${BLUE}连接信息：${NC}"
echo "  服务器: 你的服务器IP:$PORT"
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
echo "hysteria2://${MAIN_PASS}@${SERVER_IP}:$PORT/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2-300M"
echo
echo -e "${BLUE}服务管理：${NC}"
echo "  rc-service hysteria start|stop|restart|status"
echo "  监控日志: tail -f /var/log/hysteria/monitor.log"
echo "================================================================================"

# 保存配置
cat > /root/hysteria-config.txt << EOF
Hysteria2 配置信息
服务器: ${SERVER_IP}:$PORT
密码: $MAIN_PASS
混淆密码: $OBFS_PASS
SNI: www.bing.com

v2rayN链接:
hysteria2://${MAIN_PASS}@${SERVER_IP}:$PORT/?insecure=1&sni=www.bing.com&obfs=salamander&obfs-password=${OBFS_PASS}#Hysteria2
EOF

log_info "配置已保存到: /root/hysteria-config.txt"
echo
log_info "🚀 资源保护配置:"
echo "  - QUIC窗口: 2MB-8MB (保守配置)"
echo "  - 带宽限制: 200M下行/50M上行 (防止资源耗尽)"
echo "  - 内存限制: 64MB软限制/128MB硬限制"
echo "  - CPU限制: 90%使用率 + 优先级降低"
echo "  - 进程限制: 最多100个子进程"
echo "  - 监控机制: 每2分钟检查资源使用"
log_info "安装完成！资源保护已启用"

# 如果服务未运行，提供手动诊断命令
if ! ps aux | grep -v grep | grep -q hysteria; then
    echo
    log_warn "⚠️ 服务未运行，请手动诊断:"
    echo "1. 检查服务状态: rc-service hysteria status"
    echo "2. 手动启动测试: sudo -u hysteria /usr/local/bin/hysteria server --config /etc/hysteria/config.yaml"
    echo "3. 检查配置文件: cat /etc/hysteria/config.yaml"
    echo "4. 检查文件权限: ls -la /etc/hysteria/"
    echo "5. 重新启动: rc-service hysteria restart"
fi