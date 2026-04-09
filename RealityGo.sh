#!/bin/bash

echo "=== VLESS Reality 自动化部署 (密钥修复版) ==="

# 1. 环境检查
if [ "$EUID" -ne 0 ]; then
  echo "❌ 请用 root 运行"
  exit 1
fi

# 2. 安装/更新 Xray
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
XRAY_BIN="/usr/local/bin/xray"

# 3. 核心：极其稳健的密钥生成逻辑
echo "正在生成密钥..."
# 运行命令并将输出存入临时变量
KEYS_OUT=$($XRAY_BIN x25519 2>/dev/null)

# 依次尝试两种最常见的提取模式
PRIVATE=$(echo "$KEYS_OUT" | grep "Private" | awk '{print $NF}')
PUBLIC=$(echo "$KEYS_OUT" | grep "Public" | awk '{print $NF}')

# 如果还是空，尝试 fallback 模式 (直接用 cut)
if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
    PRIVATE=$(echo "$KEYS_OUT" | grep "Private" | cut -d' ' -f3)
    PUBLIC=$(echo "$KEYS_OUT" | grep "Public" | cut -d' ' -f3)
fi

# 最终检查，如果还不行就报错
if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
  echo "❌ 无法自动提取密钥，请尝试手动运行: xray x25519"
  exit 1
fi

# 4. 参数配置
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORTID=$(openssl rand -hex 4)
IP=$(curl -s ifconfig.me)
SNI="www.microsoft.com"

# 5. 写入 JSON
mkdir -p /usr/local/etc/xray
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

# 6. 权限修复
SERVICE_FILE="/etc/systemd/system/xray.service"
if [ -f "$SERVICE_FILE" ]; then
    sed -i 's/User=nobody/User=root/g' $SERVICE_FILE
    systemctl daemon-reload
fi

# 7. 启动服务
systemctl enable xray --now
systemctl restart xray

# 8. 开启 BBR
if ! lsmod | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
fi

echo ""
echo "✅ 部署完成！这次公钥应该出来了："
echo "--------------------------------"
echo "IP: $IP"
echo "端口: $PORT"
echo "UUID: $UUID"
echo "公钥(Pbk): $PUBLIC"
echo "shortId(Sid): $SHORTID"
echo "SNI: $SNI"
echo "--------------------------------"
echo "VLESS 链接:"
echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORTID&type=tcp#Reality_SelfUse"
