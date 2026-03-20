cat > /root/reality_fix.sh <<'EOF'
#!/bin/bash
SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
SNI="global.fujifilm.com"

# 1. 环境与架构检测
os_check() {
    if [[ -f /etc/redhat-release ]]; then OS_RELEASE="centos"
    elif grep -Eqi "debian" /etc/issue /proc/version 2>/dev/null; then OS_RELEASE="debian"
    elif grep -Eqi "ubuntu" /etc/issue /proc/version 2>/dev/null; then OS_RELEASE="ubuntu"
    elif grep -Eqi "alpine" /etc/issue 2>/dev/null; then OS_RELEASE="alpine"
    else OS_RELEASE="debian"; fi
}
arch_check() {
    OS_ARCH=$(arch)
    case $OS_ARCH in
        x86_64|x64|amd64) OS_ARCH="amd64" ;;
        aarch64|arm64) OS_ARCH="arm64" ;;
        *) OS_ARCH="amd64" ;;
    esac
}

# 2. 安装依赖并下载 sing-box
install_and_download() {
    echo "正在安装依赖并下载最新版 sing-box..."
    if [[ "$OS_RELEASE" == "debian" || "$OS_RELEASE" == "ubuntu" ]]; then
        apt-get update -qq && apt-get install -y curl wget jq openssl bc -qq
    else
        yum install -y curl wget jq openssl bc -q
    fi
    mkdir -p ${SING_BOX_PATH} && cd ${SING_BOX_PATH}
    local latest_version=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep 'tag_name' | head -1 | awk -F '"' '{print $4}')
    [ -z "$latest_version" ] && latest_version="v1.12.0"
    local version_num=${latest_version#v}
    wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${latest_version}/sing-box-${version_num}-linux-${OS_ARCH}.tar.gz"
    tar -xzf sing-box.tar.gz --strip-components=1 && chmod +x sing-box && rm -f sing-box.tar.gz
}

# 3. 生成配置 (适配 1.12+ 域名策略)
generate_config() {
    PORT=$(shuf -i 10000-65535 -n 1)
    UUID=$(./sing-box generate uuid)
    KEYS=$(./sing-box generate reality-keypair)
    PRIKEY=$(echo "$KEYS" | grep 'PrivateKey:' | awk '{print $2}')
    PBK=$(echo "$KEYS" | grep 'PublicKey:' | awk '{print $2}')
    SHORTID=$(openssl rand -hex 8)

    cat > "${SING_BOX_PATH}config.json" <<EOD
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
      "server_name": "$SNI",
      "reality": {
        "enabled": true,
        "handshake": {"server": "$SNI", "server_port": 443},
        "private_key": "$PRIKEY",
        "short_id": ["$SHORTID"]
      }
    }
  }],
  "outbounds": [{
    "type": "direct",
    "tag": "direct",
    "domain_strategy": "ipv4_only"
  }]
}
EOD
    # 保存分享链接
    IP=$(curl -s4m8 ip.sb || curl -s4m8 ifconfig.me)
    echo "vless://$UUID@$IP:$PORT?security=reality&encryption=none&pbk=$PBK&headerType=none&fp=chrome&type=tcp&sni=$SNI&sid=$SHORTID&flow=xtls-rprx-vision#Reality-Node" > ${SING_BOX_PATH}share.txt
}

# 4. 安装 Systemd 服务 (彻底解决 214 报错)
install_service() {
    rm -rf /etc/systemd/system/sing-box.service.d/
    cat > "$SERVICE_FILE_PATH" <<EOD
[Unit]
Description=sing-box Service
After=network.target
[Service]
Type=simple
ExecStart=${SING_BOX_PATH}sing-box run -c ${SING_BOX_PATH}config.json
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOD
    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
    systemctl reset-failed
}

# 主执行逻辑
os_check && arch_check
install_and_download
generate_config
install_service

echo -e "\n--- 安装成功 ---"
echo "节点链接已保存至: ${SING_BOX_PATH}share.txt"
cat ${SING_BOX_PATH}share.txt
echo -e "\n服务状态:"
systemctl status sing-box --no-pager
EOF

bash /root/reality_fix.sh
