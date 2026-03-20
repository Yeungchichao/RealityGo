# 1. 安装 Alpine 必备组件
apk update && apk add curl wget jq openssl bc openrc

# 2. 创建目录并下载适配 Alpine 的 sing-box
mkdir -p /etc/sing-box/ && cd /etc/sing-box/
LATEST=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
ARCH=$(arch | sed 's/x86_64/amd64/;s/aarch64/arm64/')
wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${LATEST}/sing-box-${LATEST#v}-linux-${ARCH}.tar.gz"
tar -xzf sing-box.tar.gz --strip-components=1 && chmod +x sing-box

# 3. 编写 Alpine 专用启动脚本 (OpenRC)
cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-Box Service"
supervisor="supervise-daemon"
command="/etc/sing-box/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_user="root:root"

depend() {
    after net dns
    use net
}
EOF
chmod +x /etc/init.d/sing-box

# 4. 重新生成配置 (适配 1.12+ 语法)
PORT=$(shuf -i 10000-65535 -n 1)
UUID=$(/etc/sing-box/sing-box generate uuid)
KEYS=$(/etc/sing-box/sing-box generate reality-keypair)
PRIKEY=$(echo "\$KEYS" | grep 'PrivateKey:' | awk '{print \$2}')
PBK=$(echo "\$KEYS" | grep 'PublicKey:' | awk '{print \$2}')
SHORTID=$(openssl rand -hex 8)

cat > /etc/sing-box/config.json <<EOF
{
  "log": {"level": "info", "timestamp": true},
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": $PORT,
    "users": [{"uuid": "$UUID", "flow": "xtls-rprx-vision"}],
    "tls": {
      "enabled": true,
      "server_name": "global.fujifilm.com",
      "reality": {
        "enabled": true,
        "handshake": {"server": "global.fujifilm.com", "server_port": 443},
        "private_key": "$PRIKEY",
        "short_id": ["$SHORTID"]
      }
    }
  }],
  "outbounds": [{"type": "direct", "tag": "direct", "domain_strategy": "ipv4_only"}]
}
EOF

# 5. 启动服务并设置开机自启
rc-update add sing-box default
rc-service sing-box restart

# 6. 生成并打印链接
IP=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me)
echo -e "\n--- Alpine 专用节点链接 ---"
echo "vless://$UUID@$IP:$PORT?security=reality&encryption=none&pbk=$PBK&headerType=none&fp=chrome&type=tcp&sni=global.fujifilm.com&sid=$SHORTID&flow=xtls-rprx-vision#Alpine-Reality"
echo -e "\n服务状态:"
rc-service sing-box status
