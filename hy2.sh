#!/bin/sh

set -eu

# 检查是否为 root
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 身份运行此脚本" >&2
  exit 1
fi

# 安装最小依赖
apk add --no-cache curl openssl ca-certificates openrc

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
  cat << EOF
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

echo "------------------------------------------------------------------------"
echo "hysteria2 已经安装完成"
echo "默认端口： 40443 ， 密码为： $GENPASS ，工具中配置：tls，SNI为： bing.com"
echo "配置文件：/etc/hysteria/config.yaml"
echo "已经随系统自动启动（若 openrc 可用）"
echo "查看状态： service hysteria status"
echo "重启： service hysteria restart"
echo "请享用。"
echo "------------------------------------------------------------------------"