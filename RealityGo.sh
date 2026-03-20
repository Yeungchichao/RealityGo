#!/bin/bash

SING_BOX_PATH="/etc/sing-box/"
SERVICE_FILE_PATH='/etc/systemd/system/sing-box.service'
SHARE_LINKS=""

# --- 核心改进：环境检测与依赖前置 ---
# 自动检测并安装最基础的 curl
install_initial_dependencies() {
    if ! command -v curl > /dev/null; then
        echo "检测到缺失 curl，正在尝试安装..."
        if command -v apt-get > /dev/null; then
            apt-get update -qq && apt-get install -y curl -qq
        elif command -v yum > /dev/null; then
            yum install -y curl -q
        elif command -v apk > /dev/null; then
            apk add curl
        fi
    fi
}

# 生成 10000 到 65535 之间的随机端口
PORT=$(shuf -i 10000-65535 -n 1)
SNI="global.fujifilm.com"

# 全局变量
IPV4=""
IPV6=""
HAS_IPV4=0
HAS_IPV6=0

# 停止现有服务
stop_singbox_if_running() {
    if systemctl is-active --quiet sing-box || pgrep -x "sing-box" > /dev/null; then
        echo "正在停止旧的 sing-box 服务..."
        systemctl stop sing-box 2>/dev/null || service sing-box stop 2>/dev/null
        sleep 1
    fi
}

# [此处省略原脚本中重复的 IP 获取、翻译、硬件检测函数，逻辑保持不变]
# ... (中间函数 get_ip_addresses, fetch_ip_details, get_server_specs 等) ...

# --- 重点改进：Systemd 服务安装 ---
install_systemd_service() {
    echo "正在安装/更新 systemd 服务..."
    
    # 清理旧的错误配置补丁（防止 214/SETSCHEDULER 报错残留）
    rm -rf /etc/systemd/system/sing-box.service.d/priority.conf
    
    if [[ "$OS_RELEASE" == "alpine" ]]; then 
        # Alpine OpenRC 配置保持原样
        [...省略部分...]
    else 
        # 标准 Systemd 配置
        cat > "$SERVICE_FILE_PATH" <<EOF
[Unit]
Description=sing-box Service
Documentation=https://sing-box.sagernet.org/
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
ExecStart=${SING_BOX_PATH}sing-box run -c ${SING_BOX_PATH}config.json
Restart=on-failure
RestartSec=10s
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
        chmod +x "$SERVICE_FILE_PATH"

        # 智能检测：仅在 KVM/VMware 等非容器环境下开启高优先级调度
        if systemd-detect-virt -q --container; then
            echo "检测到容器环境 (LXC/OpenVZ)，跳过高优先级 CPU 调度设置以确保稳定。"
        else
            echo "检测到独立虚拟化环境，尝试开启 CPU 调度优化..."
            mkdir -p /etc/systemd/system/sing-box.service.d
            echo -e "[Service]\nCPUSchedulingPolicy=rr\nCPUSchedulingPriority=99" > /etc/systemd/system/sing-box.service.d/priority.conf
        fi
        
        systemctl daemon-reload
        systemctl enable sing-box
    fi
}

# [此处省略原脚本中的下载、生成配置、分享链接函数，逻辑保持不变]
# ... (中间函数 download_sing_box, generate_reality_config, gen_share_link 等) ...

# --- 主流程入口 ---
main() {
    echo "开始执行 sing-box Reality 节点增强版脚本..."
    install_initial_dependencies
    stop_singbox_if_running
    os_check
    arch_check
    install_base 
    
    get_ip_addresses 
    if [[ $HAS_IPV4 -eq 1 ]]; then fetch_ip_details "$IPV4" "v4"; fi
    if [[ $HAS_IPV6 -eq 1 ]]; then fetch_ip_details "$IPV6" "v6"; fi
    get_server_specs 

    download_sing_box 
    
    # 密钥生成逻辑
    KEYS=$(${SING_BOX_PATH}sing-box generate reality-keypair)
    PRIKEY=$(echo "$KEYS" | grep 'PrivateKey:' | awk '{print $2}') 
    PBK=$(echo "$KEYS" | grep 'PublicKey:' | awk '{print $2}')    
    UUID=$(${SING_BOX_PATH}sing-box generate uuid)
    SHORTID=$(openssl rand -hex 8)

    # 配置并安装服务
    generate_reality_config "$PORT" "$UUID" "$PRIKEY" "$SHORTID" "$SNI"
    install_systemd_service

    # 启动与状态检查
    systemctl restart sing-box 2>/dev/null || service sing-box restart 2>/dev/null
    sleep 2
    
    # [后续展示链接及卸载提示逻辑保持不变]
    # ...
}

main
