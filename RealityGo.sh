#!/bin/bash

echo "=== VLESS Reality 官方标准版安装 ==="

# 必须 root
if [ "$EUID" -ne 0 ]; then
  echo "请用 root 运行"
  exit 1
fi

# 安装/修复 Xray
bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

# 确保 xray 可执行
XRAY_BIN="/usr/local/bin/xray"
if [ ! -f "$XRAY_BIN" ]; then
  XRAY_BIN=$(which xray)
fi

if [ ! -f "$XRAY_BIN" ]; then
  echo "❌ Xray 未安装成功"
  exit 1
fi

chmod +x $XRAY_BIN

# ===== 关键：循环生成密钥（保证成功）=====
echo "生成 Reality 密钥..."
for i in {1..5}; do
  KEYS=$($XRAY_BIN x25519 2>/dev/null)
PRIVATE=$(echo "$KEYS" | grep -i private | awk -F ': ' '{print $2}')
PUBLIC=$(echo "$KEYS" | grep -i public | awk -F ': ' '{print $2}')

  if [[ -n "$PRIVATE" && -n "$PUBLIC" ]]; then
    break
  fi
done

if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
  echo "❌ 密钥生成失败，尝试重新安装 Xray..."
  rm -f /usr/local/bin/xray
  bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)

  KEYS=$(/usr/local/bin/xray x25519)
  PRIVATE=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
  PUBLIC=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
fi

if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
  echo "❌ 最终仍无法生成密钥，请手动执行 xray x25519"
  exit 1
fi

# 生成其他参数
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
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

# 修复权限（避免 nobody 问题）
sed -i '/User=nobody/d' /etc/systemd/system/xray.service 2>/dev/null

# 启动
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# 放行端口
ufw allow $PORT 2>/dev/null

echo ""
echo "====== Reality 节点信息 ======"
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
echo "=== 部署完成 🚀 ==="
