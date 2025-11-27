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

# 安装最小依赖
apk add --no-cache curl openssl ca-certificates openrc chrony

# 1. 配置时间同步 (关键：Hysteria 依赖准确的时间)
echo "正在配置时间同步..."
rc-update add chronyd default || true
service chronyd start || echo "警告: 启动 chronyd 失败 (可能是容器权限限制)，将尝试继续..."
# 尝试立即同步一次
chronyc -a makestep || true

# 2. 检查并添加 Swap (关键：128MB 内存必须有 Swap)
check_and_add_swap() {
  if [ -f /swapfile ]; then
    echo "Swap 文件已存在，跳过创建。"
  elif free | grep -q "Swap:.*[1-9]"; then
    echo "系统已有 Swap，跳过创建。"
  else
    echo "正在创建 512MB Swap 文件..."
    # 使用 dd 创建 512MB 文件 (512 * 1024 = 524288)
    dd if=/dev/zero of=/swapfile bs=1024 count=524288
    chmod 600 /swapfile
    mkswap /swapfile
    # 容器环境可能无法挂载 Swap，允许失败
    if ! swapon /swapfile; then
        echo "警告: 挂载 Swap 失败 (可能是容器权限限制)。"
        echo "注意: 在 128MB 内存下如果没有 Swap，Hysteria 可能会不稳定。"
        # 删除创建失败的文件
        rm -f /swapfile
    else
        # 写入 fstab 实现开机挂载
        echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
        echo "Swap 创建成功。"
    fi
  fi
}
check_and_add_swap

log_info "开始安装 Hysteria2 (安全优化版)"

# 安装系统依赖
log_info "安装系统依赖..."
apk update && apk add wget openssl

# 生成随机密码
generate_password() {
    # 使用 tr 生成更兼容的随机密码
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

MAIN_PASS=$(generate_password)
OBFS_PASS=$(generate_password)

# 安全的IP获取函数
get_server_ip() {
    local ip=""
    # 尝试多个IP查询服务
    local services="ipinfo.io/ip api.ipify.org icanhazip.com ident.me checkip.amazonaws.com"
    
    for service in $services; do
        ip=$(curl -s -4 --connect-timeout 5 "$service" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    
    # 获取失败时返回空，后续处理
    echo ""
}

SERVER_IP=$(get_server_ip)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP="YOUR_SERVER_IP"
fi

# 3. 端口设置
# 生成 20000-60000 之间的随机端口
get_random_port() {
  awk -v min=20000 -v max=60000 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
}

DEFAULT_PORT="$(get_random_port)"
PORT=""

while true; do
  echo -n "请输入端口 (20000-60000) [默认: $DEFAULT_PORT]: "
  read input_port
  
  if [ -z "$input_port" ]; then
    PORT="$DEFAULT_PORT"
    break
  fi
  
  # 检查是否为数字
  if ! echo "$input_port" | grep -qE '^[0-9]+$'; then
    log_error "错误：请输入有效的数字。"
    continue
  fi
  
  # 检查范围
  if [ "$input_port" -lt 20000 ] || [ "$input_port" -gt 60000 ]; then
    log_error "错误：端口必须在 20000 到 60000 之间。"
    continue
  fi
  
  PORT="$input_port"
  break
done

log_info "使用端口: $PORT"

# 配置BBR
configure_bbr() {
    if grep -q "bbr" /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null; then
        log_info "BBR 已启用"
        return 0
    fi
    
    # 容器环境可能只读，允许失败
    cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.somaxconn = 1024
EOF

    sysctl -p >/dev/null 2>&1 && log_info "BBR 配置完成" || log_warn "BBR 配置失败 (可能是容器限制)，跳过。"
}

configure_bbr

# 创建目录结构
log_info "创建目录结构..."
mkdir -p /etc/hysteria /var/log/hysteria

# 生成证书
log_info "生成TLS证书..."
# 使用两步法生成证书，兼容性更好，并显示错误信息
if ! openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/server.key; then
    log_error "生成私钥失败！"
    exit 1
fi

if ! openssl req -x509 -new -key /etc/hysteria/server.key -sha256 -days 36500 -out /etc/hysteria/server.crt -subj "/CN=www.bing.com"; then
    log_error "生成证书失败！"
    exit 1
fi

chmod 600 /etc/hysteria/server.key
chmod 644 /etc/hysteria/server.crt

# 写入配置文件
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
chmod +x /usr/local/bin/hysteria

# 启动服务
service hysteria start || true

# 生成分享链接
# 格式: hysteria2://password@host:port/?sni=sni_domain&insecure=1#name
# 注意: 自签名证书需要 insecure=1
SHARE_LINK="hysteria2://${MAIN_PASS}@${SERVER_IP}:${PORT}/?sni=www.bing.com&insecure=1#Hysteria2-Alpine"

echo "------------------------------------------------------------------------"
echo "hysteria2 已经安装完成"
echo "------------------------------------------------------------------------"
echo "配置详情："
echo "  端口: $PORT"
echo "  密码: $MAIN_PASS"
echo "  SNI : www.bing.com"
echo "  证书: 自签名 (客户端需开启跳过证书验证/insecure)"
echo ""
echo "分享链接 (复制到客户端导入):"
echo "$SHARE_LINK"
echo ""
echo "系统状态："
echo "  配置文件: /etc/hysteria/config.yaml"
echo "  服务状态: service hysteria status"
echo "  Swap状态: $(free -h | grep Swap | awk '{print $2}')"
echo "------------------------------------------------------------------------"