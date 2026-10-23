#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu：使用 sing-box 部署 VLESS + REALITY
# 运行：sudo bash deploy_singbox_reality.sh
SB_BIN="/usr/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"

fail() { echo "❌ $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "请使用 root 权限运行：sudo bash $0"
command -v apt-get >/dev/null 2>&1 || fail "此脚本仅支持 Debian/Ubuntu 系（需要 apt-get）。"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl iproute2 gnupg
need_cmd systemctl
need_cmd ss
need_cmd runuser
need_cmd namei
need_cmd install

# 添加 sing-box 官方 APT 仓库并安装稳定版
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
chmod a+r /etc/apt/keyrings/sagernet.asc
cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
apt-get update
apt-get install -y sing-box
command -v sing-box >/dev/null 2>&1 || fail "sing-box 安装失败。"
SB_BIN=$(command -v sing-box)
systemctl cat sing-box.service >/dev/null 2>&1 || fail "安装后未找到 sing-box.service。"

# 读取服务运行用户，按其权限设置配置文件
SB_USER=$(systemctl show sing-box.service -p User --value 2>/dev/null || true)
[[ -n "$SB_USER" ]] || SB_USER="root"
id "$SB_USER" >/dev/null 2>&1 || fail "sing-box 服务用户不存在：$SB_USER"
SB_GROUP=$(id -gn "$SB_USER")
echo "sing-box 服务运行身份：${SB_USER}:${SB_GROUP}"

# 选择 Reality handshake SNI
SNI_OPTIONS=(
  "gateway.icloud.com" "itunes.apple.com" "swdist.apple.com"
  "swcdn.apple.com" "updates.cdn-apple.com" "mensura.cdn-apple.com"
  "osxapps.itunes.apple.com" "aod.itunes.apple.com" "learn.microsoft.com"
  "addons.mozilla.org" "global.fujifilm.com" "m.media-amazon.com"
  "www.lovelive-anime.jp" "academy.nvidia.com" "www.tesla.com"
  "www.python.org" "vuejs.org" "vuejs-jp.org" "zh-hk.vuejs.org"
  "react.dev" "www.java.com" "www.oracle.com" "www.mysql.com"
  "www.mongodb.com" "redis.io" "www.swift.com" "www.cisco.com"
  "www.asus.com" "www.samsung.com" "www.amd.com" "www.umcg.nl"
  "www.fom-international.com" "www.u-can.co.jp" "github.io" "自定义输入"
)
echo "请选择 REALITY handshake 域名/SNI："
select opt in "${SNI_OPTIONS[@]}"; do
  [[ -n "${opt:-}" ]] || { echo "请输入有效序号。"; continue; }
  if [[ "$opt" == "自定义输入" ]]; then
    read -r -p "输入域名（不含协议、端口、路径）: " SNI
  else
    SNI="$opt"
  fi
  break
done
[[ "$SNI" =~ ^[A-Za-z0-9.-]+$ ]] || fail "域名格式不合法：$SNI"
[[ "$SNI" != .* && "$SNI" != *. && "$SNI" != *..* ]] || fail "域名格式不合法：$SNI"

# Reality handshake 目标检查
if ! curl -sSIL --max-time 8 "https://${SNI}/" >/dev/null; then
  echo "⚠️ 服务器无法通过 HTTPS 访问 https://${SNI}/ 。"
  read -r -p "仍然继续？[y/N] " CONTINUE
  [[ "$CONTINUE" =~ ^[Yy]$ ]] || fail "已取消，请选择本机可访问的目标域名。"
fi

# sing-box 自带 Reality 密钥生成命令
KEYS_OUT=$("$SB_BIN" generate reality-keypair 2>&1) || fail "sing-box 生成 Reality 密钥失败：$KEYS_OUT"
PRIVATE=$(printf '%s\n' "$KEYS_OUT" | awk -F ': *' 'tolower($1) ~ /private/ {print $NF; exit}')
PUBLIC=$(printf '%s\n' "$KEYS_OUT" | awk -F ': *' 'tolower($1) ~ /(public|password)/ {print $NF; exit}')
[[ -n "$PRIVATE" && -n "$PUBLIC" ]] || fail "无法识别 sing-box Reality 密钥输出格式：$KEYS_OUT"

UUID=$(cat /proc/sys/kernel/random/uuid)
SHORTID=$(openssl rand -hex 8)

# 选取随机且当前未监听的高位 TCP 端口
PORT=""
for _ in $(seq 1 100); do
  CANDIDATE=$(shuf -i 20000-60000 -n 1)
  if ! ss -lntH "sport = :$CANDIDATE" | grep -q .; then
    PORT="$CANDIDATE"
    break
  fi
done
[[ -n "$PORT" ]] || fail "无法找到空闲 TCP 端口。"

# 探测公网地址
IP=""
for url in https://api.ipify.org https://ifconfig.me/ip https://ip.sb; do
  IP=$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)
  [[ -n "$IP" ]] && break
done
if [[ -z "$IP" ]]; then
  read -r -p "无法自动获取公网 IP，请输入服务器公网 IP/域名: " IP
fi
[[ -n "$IP" ]] || fail "服务器公网 IP/域名不能为空。"

# 临时 JSON 文件必须以 .json 结尾，先校验，再替换正式配置
install -d -o root -g "$SB_GROUP" -m 750 "$CONFIG_DIR"
TMP_CONFIG=$(mktemp "$CONFIG_DIR/config.XXXXXX.json")
BACKUP=""
cleanup() { rm -f "${TMP_CONFIG:-}"; }
trap cleanup EXIT
cat >"$TMP_CONFIG" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": $PORT,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE",
          "short_id": ["$SHORTID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
chown root:"$SB_GROUP" "$TMP_CONFIG"
chmod 640 "$TMP_CONFIG"
"$SB_BIN" check -c "$TMP_CONFIG" || fail "sing-box 配置校验失败；现有配置尚未被覆盖。"

if [[ -f "$CONFIG_FILE" ]]; then
  BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$CONFIG_FILE" "$BACKUP"
fi
install -o root -g "$SB_GROUP" -m 640 "$TMP_CONFIG" "$CONFIG_FILE"

systemctl daemon-reload
systemctl enable sing-box.service >/dev/null
if ! systemctl restart sing-box.service; then
  echo "❌ sing-box 启动失败，最近日志：" >&2
  journalctl -u sing-box.service -n 80 --no-pager >&2 || true
  if [[ -n "$BACKUP" ]]; then
    cp -a "$BACKUP" "$CONFIG_FILE"
    systemctl restart sing-box.service || true
    echo "已尝试恢复旧配置：$BACKUP" >&2
  fi
  fail "sing-box 服务启动失败。"
fi
sleep 2
if ! systemctl is-active --quiet sing-box.service; then
  journalctl -u sing-box.service -n 80 --no-pager >&2 || true
  if [[ -n "$BACKUP" ]]; then
    cp -a "$BACKUP" "$CONFIG_FILE"
    systemctl restart sing-box.service || true
    echo "已尝试恢复旧配置：$BACKUP" >&2
  fi
  fail "sing-box 服务未处于 active 状态。"
fi

# 用服务身份复核配置读取与解析
if ! runuser -u "$SB_USER" -- "$SB_BIN" check -c "$CONFIG_FILE"; then
  echo "❌ 服务用户无法读取或校验正式配置：" >&2
  namei -l "$CONFIG_FILE" >&2 || true
  journalctl -u sing-box.service -n 60 --no-pager >&2 || true
  fail "正式配置校验失败。"
fi

# 本机 UFW 放行；云安全组需要用户在云控制台单独放行
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" || echo "⚠️ UFW 放行失败，请手动放行 TCP $PORT。" >&2
fi
if ss -lntH "sport = :$PORT" | grep -q .; then
  echo "✅ TCP $PORT 正在本机监听。"
else
  journalctl -u sing-box.service -n 80 --no-pager >&2 || true
  fail "服务 active 但端口 $PORT 未监听。"
fi

# VLESS 分享链接；客户端需支持 REALITY 和 Vision
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC}&sid=${SHORTID}&type=tcp#sing-box-Reality_${SNI}"
echo
echo "✅ sing-box 部署完成：配置检查通过、服务 active、TCP 端口本机监听。"
echo "注意：请在云厂商安全组/网络 ACL 放行入站 TCP $PORT。此脚本不能从服务器验证公网入站可达性。"
echo "--------------------------------"
echo "服务器地址: $IP"
echo "端口: $PORT/TCP"
echo "UUID: $UUID"
echo "公钥 (pbk): $PUBLIC"
echo "Short ID (sid): $SHORTID"
echo "SNI: $SNI"
echo "配置文件: $CONFIG_FILE"
echo "服务运行身份: ${SB_USER}:${SB_GROUP}"
[[ -n "$BACKUP" ]] && echo "旧配置备份: $BACKUP"
echo "--------------------------------"
echo "VLESS 链接（含访问凭据，请勿公开）:"
echo "$LINK"
echo "--------------------------------"
echo "从另一台机器测试 TCP 端口：nc -vz $IP $PORT"
