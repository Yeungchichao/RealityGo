#!/bin/bash

echo "=== VLESS Reality 极致优化版 (自用专用) ==="

# 1. 基础检查与组件安装
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请用 root 运行"
  exit 1
fi

# 安装必要组件 (避免精简系统报错)
apt-get update && apt-get install -y curl openssl socat >/dev/null 2>&1 || yum install -y curl openssl socat

# 2. 安装/修复 Xray
echo "正在获取官方最新版 Xray..."
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

XRAY_BIN="/usr/local/bin/xray"
[ ! -f "$XRAY_BIN" ] && XRAY_BIN=$(which xray)

if [ ! -f "$XRAY_BIN" ]; then
  echo "❌ Xray 安装失败"
  exit 1
fi

# 3. 开启内核 BBR 加速
if ! lsmod | grep -q "bbr"; then
    echo "正在开启 BBR 加速..."
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

# 4. 生成 Reality 密钥 (增强兼容性)
echo "生成 Reality 密钥..."
KEYS=$($XRAY_BIN x25519 2>/dev/null)
PRIVATE=$(echo "$KEYS" | awk '/Private key:/ {print $3}')
PUBLIC=$(echo "$KEYS" | awk '/Public key:/ {print $3}')

# 5. 自动配置参数
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORTID=$(openssl rand -hex 4)
IP=$(curl -s ifconfig.me)
SNI="www.microsoft.com" # 默认改为更通用的微软域名

# 6. 写入配置文件
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "$UUID",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "$SNI:443",
        "xver": 0,
        "serverNames": ["$SNI"],
        "privateKey": "$PRIVATE",
        "shortIds": ["$SHORTID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 7. 彻底解决权限问题
SERVICE_FILE="/etc/systemd/system/xray.service"
if [ -f "$SERVICE_FILE" ]; then
    # 将 User=nobody 改为 User=root，确保能读取配置和监听高位端口
    sed -i 's/User=nobody/User=root/g' $SERVICE_FILE
    systemctl daemon-reload
fi

# 8. 启动服务
systemctl enable xray --now
systemctl restart xray

# 9. 防火墙处理 (兼容 ufw 和直接放行)
if command -v ufw > /dev/null; then
    ufw allow $PORT/tcp >/dev/null 2>&1
fi

echo ""
echo "✅ 部署完成！"
echo "--------------------------------"
echo "IP: $IP"
echo "端口: $PORT"
echo "UUID: $UUID"
echo "公钥: $PUBLIC"
echo "shortId: $SHORTID"
echo "SNI: $SNI"
echo "--------------------------------"
echo "VLESS 链接 (复制到客户端即可):"
echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORTID&type=tcp#Reality_SelfUse"
