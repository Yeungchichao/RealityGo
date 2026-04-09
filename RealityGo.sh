#!/bin/bash

echo "=== 安装 VLESS Reality（全自动）==="

# 安装 Xray
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

# 生成参数
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
KEYS=$(xray x25519 2>/dev/null)

if [[ -z "$KEYS" ]]; then
  KEYS=$(/usr/local/bin/xray x25519 2>/dev/null)
fi

PRIVATE=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
PUBLIC=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
SHORTID=$(openssl rand -hex 4)
IP=$(curl -s ifconfig.me)

# 写配置
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
        "dest": "addons.mozilla.org:443",
        "xver": 0,
        "serverNames": ["addons.mozilla.org"],
        "privateKey": "$PRIVATE",
        "shortIds": ["$SHORTID"]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

# 启动
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 放行端口
ufw allow $PORT 2>/dev/null

# 输出信息
echo ""
echo "====== VLESS Reality 信息 ======"
echo "IP: $IP"
echo "端口: $PORT"
echo "UUID: $UUID"
echo "公钥: $PUBLIC"
echo "shortId: $SHORTID"
echo "SNI: addons.mozilla.org"

echo ""
echo "====== VLESS 链接 ======"
echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=addons.mozilla.org&fp=chrome&pbk=$PUBLIC&sid=$SHORTID&type=tcp#Reality"

echo ""
echo "====== Clash 配置 ======"
cat <<EOC
proxies:
  - name: Reality
    type: vless
    server: $IP
    port: $PORT
    uuid: $UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: addons.mozilla.org
    reality-opts:
      public-key: $PUBLIC
      short-id: $SHORTID
    client-fingerprint: chrome
EOC

echo ""
echo "=== 完成 🚀 ==="
