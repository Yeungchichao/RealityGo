#!/bin/bash

echo "=== VLESS Reality 自动化部署 (适配你的特定版本) ==="

# 1. 基础环境
XRAY_BIN="/usr/local/bin/xray"
if [ ! -f "$XRAY_BIN" ]; then
    echo "正在安装 Xray..."
    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
fi

# 2. 核心：适配你的输出格式提取密钥
echo "正在提取密钥..."
KEYS_OUT=$($XRAY_BIN x25519 2>/dev/null)

# 适配 PrivateKey:
PRIVATE=$(echo "$KEYS_OUT" | grep "PrivateKey" | awk '{print $2}')

# 适配 Password (PublicKey):
# 这里直接提取该行最后一个空格后的内容
PUBLIC=$(echo "$KEYS_OUT" | grep "PublicKey" | awk '{print $NF}')

if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
    echo "❌ 提取失败，请检查输出格式。"
    exit 1
fi

# 3. 自动配置参数
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORTID=$(openssl rand -hex 4)
IP=$(curl -s ifconfig.me)
SNI="www.microsoft.com"

# 4. 写入 JSON 配置文件
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

# 5. 权限与服务启动
SERVICE_FILE="/etc/systemd/system/xray.service"
if [ -f "$SERVICE_FILE" ]; then
    sed -i 's/User=nobody/User=root/g' $SERVICE_FILE
    systemctl daemon-reload
fi
systemctl enable xray --now
systemctl restart xray

echo ""
echo "✅ 部署成功！"
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
