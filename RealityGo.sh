#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本！"
    exit 1
fi

echo "=== VLESS Reality 自动化部署 (全量支持自定义 SNI) ==="

# 0. 自动安装依赖
echo "正在检查并安装基础依赖..."
if ! command -v unzip &> /dev/null; then
    apt update && apt install -y unzip curl openssl
fi

# 1. 基础环境
XRAY_BIN="/usr/local/bin/xray"
if [ ! -f "$XRAY_BIN" ]; then
    echo "正在安装 Xray..."
    bash <(curl -Ls https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
fi

# 2. 交互式选择 SNI (伪装域名)
echo "--------------------------------"
echo "请选择你要使用的 SNI 伪装域名："
echo "--------------------------------"

# 整合你提供的所有域名列表
SNI_OPTIONS=(
    "gateway.icloud.com"
    "itunes.apple.com"
    "swdist.apple.com"
    "swcdn.apple.com"
    "updates.cdn-apple.com"
    "mensura.cdn-apple.com"
    "osxapps.itunes.apple.com"
    "aod.itunes.apple.com"
    "download-installer.cdn.mozilla.net"
    "addons.mozilla.org"
    "images-na.ssl-images-amazon.com"
    "m.media-amazon.com"
    "www.lovelive-anime.jp"
    "academy.nvidia.com"
    "software.download.prss.microsoft.com"
    "www.python.org"
    "vuejs.org"
    "vuejs-jp.org"
    "zh-hk.vuejs.org"
    "react.dev"
    "www.java.com"
    "www.oracle.com"
    "www.mysql.com"
    "www.mongodb.com"
    "redis.io"
    "www.swift.com"
    "www.cisco.com"
    "www.asus.com"
    "www.samsung.com"
    "www.amd.com"
    "www.umcg.nl"
    "www.fom-international.com"
    "www.u-can.co.jp"
    "github.io"
    "自定义输入"
)

# 使用 COLUMNS 变量让菜单在大屏幕上更美观（多列显示）
export COLUMNS=80

PS3="请输入选项数字 [1-${#SNI_OPTIONS[@]}]: "
select opt in "${SNI_OPTIONS[@]}"; do
    case $opt in
        "自定义输入")
            read -p "请输入你自己的 SNI 域名: " SNI
            if [ -z "$SNI" ]; then
                echo "输入不能为空，默认使用 gateway.icloud.com"
                SNI="gateway.icloud.com"
            fi
            break
            ;;
        *)
            if [ -n "$opt" ]; then
                SNI=$opt
                break
            else
                echo "⚠️ 输入错误，请输入有效的数字！"
            fi
            ;;
    esac
done

echo "--------------------------------"
echo "🎯 已选择 SNI: $SNI"
echo "--------------------------------"

# 3. 核心：自适应提取密钥
echo "正在提取密钥..."
KEYS_OUT=$($XRAY_BIN x25519 2>/dev/null)
PRIVATE=$(echo "$KEYS_OUT" | grep -i "Private" | awk '{print $NF}')
PUBLIC=$(echo "$KEYS_OUT" | grep -i "Public" | awk '{print $NF}')

if [[ -z "$PRIVATE" || -z "$PUBLIC" ]]; then
    echo "❌ 密钥提取失败，请检查 Xray 是否正常安装。"
    exit 1
fi

# 4. 自动配置参数
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORTID=$(openssl rand -hex 4)

echo "正在获取公网 IP..."
IP=$(curl -s --max-time 5 ifconfig.me || curl -s --max-time 5 api.ipify.org || curl -s --max-time 5 ip.sb)
if [ -z "$IP" ]; then
    echo "⚠️ 无法自动获取公网 IP，请手动替换链接中的 IP 地址。"
    IP="YOUR_SERVER_IP"
fi

# 5. 写入 JSON 配置文件
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

# 6. 权限与服务启动
SERVICE_FILE="/etc/systemd/system/xray.service"
if [ -f "$SERVICE_FILE" ]; then
    sed -i 's/User=nobody/User=root/g' $SERVICE_FILE
    systemctl daemon-reload
fi
systemctl enable xray --now &>/dev/null
systemctl restart xray

# 7. 打印结果
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
echo "VLESS 链接 (可直接复制到客户端):"
echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC&sid=$SHORTID&type=tcp#Reality_$SNI"
