#!/bin/sh

set -eu

# 检查是否为 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行此脚本" >&2
  exit 1
fi

# 安装最小依赖
apk add --no-cache curl openssl ca-certificates openrc chrony

# 1. 配置时间同步 (关键：Hysteria 依赖准确的时间)
echo "正在配置时间同步..."
rc-update add chronyd default || true
service chronyd start || true
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
    swapon /swapfile
    # 写入 fstab 实现开机挂载
    echo "/swapfile swap swap defaults 0 0" >> /etc/fstab
    echo "Swap 创建成功。"
  fi
}
check_and_add_swap

generate_random_password() {
  # 生成一个 16 字节的字母数字密码，避免 YAML 解析问题
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16 || true
}

GENPASS="$(generate_random_password)"

echo_hysteria_config_yaml() {
  cat << EOF
listen: :40443

#有域名，使用CA证书
#acme:
#  domains:
#    - test.heybro.bid #你的域名，需要先解析到服务器ip
#  email: xxx@gmail.com

#使用自签名证书
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: "$GENPASS"

masquerade:
  type: proxy
  proxy:
    url: https://bing.com/
    rewriteHost: true
EOF
}

echo_hysteria_autoStart(){
  cat << 'EOF'
#!/sbin/openrc-run

name="hysteria"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"


pidfile="/var/run/${name}.pid"

command_background="yes"

depend() {
        need networking
}

EOF
}

# 根据架构选择合适的二进制（尽量覆盖常见架构）
arch="$(uname -m || true)"
case "$arch" in
  x86_64|amd64)
    bin_url="https://download.hysteria.network/app/latest/hysteria-linux-amd64"
    ;;
  aarch64|arm64)
    bin_url="https://download.hysteria.network/app/latest/hysteria-linux-arm64"
    ;;
  armv7l|armv7)
    bin_url="https://download.hysteria.network/app/latest/hysteria-linux-armv7"
    ;;
  *)
    echo "不支持的 CPU 架构：$arch" >&2
    exit 1
    ;;
esac

mkdir -p /usr/local/bin
echo "下载 hysteria 二进制： $bin_url"
if ! curl -fsSL -o /usr/local/bin/hysteria "$bin_url"; then
  echo "下载 hysteria 二进制失败" >&2
  exit 1
fi
chmod +x /usr/local/bin/hysteria

mkdir -p /etc/hysteria/

# 生成 EC 私钥并使用该密钥创建自签名证书（不依赖 bash 的 process substitution）
if ! openssl ecparam -name prime256v1 -genkey -noout -out /etc/hysteria/server.key; then
  echo "生成私钥失败" >&2
  exit 1
fi

if ! openssl req -x509 -new -key /etc/hysteria/server.key -sha256 -days 36500 -out /etc/hysteria/server.crt -subj "/CN=bing.com"; then
  echo "生成自签名证书失败" >&2
  exit 1
fi

# 写配置文件（密码用引号包裹以防特殊字符）
echo_hysteria_config_yaml > "/etc/hysteria/config.yaml"

# 写自启动脚本
echo_hysteria_autoStart > "/etc/init.d/hysteria"
chmod +x /etc/init.d/hysteria

# 启用自启动到 default 运行级别
rc-update add hysteria default || true

# 启动服务
service hysteria start || true

# 获取公网 IP (尝试获取，失败则提示用户手动填写)
PUBLIC_IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")

# 生成分享链接
# 格式: hysteria2://password@host:port/?sni=sni_domain&insecure=1#name
# 注意: 自签名证书需要 insecure=1
SHARE_LINK="hysteria2://${GENPASS}@${PUBLIC_IP}:40443/?sni=bing.com&insecure=1#Hysteria2-Alpine"

echo "------------------------------------------------------------------------"
echo "hysteria2 已经安装完成"
echo "------------------------------------------------------------------------"
echo "配置详情："
echo "  端口: 40443"
echo "  密码: $GENPASS"
echo "  SNI : bing.com"
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