#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu：部署 Xray VLESS + REALITY
# 使用方式：sudo bash deploy_vless_reality_fixed.sh
XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"

fail() { echo "❌ $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "请使用 root 权限运行：sudo bash $0"

# 安装常用依赖
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl openssl unzip iproute2
else
  need_cmd curl
  need_cmd openssl
fi
need_cmd curl
need_cmd openssl
need_cmd systemctl
need_cmd ss
need_cmd install

# 安装 Xray
if [[ ! -x "$XRAY_BIN" ]]; then
  echo "正在安装 Xray..."
  bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh)
fi
[[ -x "$XRAY_BIN" ]] || fail "Xray 未安装成功：$XRAY_BIN 不存在或不可执行。"

# 等待官方安装创建 systemd 服务
systemctl cat xray.service >/dev/null 2>&1 || fail "找不到 xray.service。请检查 Xray 安装脚本是否成功。"

# 从 systemd 服务读取运行用户。未设置 User 时按 root 处理。
XRAY_USER=$(systemctl show xray.service -p User --value 2>/dev/null || true)
[[ -n "$XRAY_USER" ]] || XRAY_USER="root"
id "$XRAY_USER" >/dev/null 2>&1 || fail "systemd 服务指定的用户不存在：$XRAY_USER"
XRAY_GROUP=$(id -gn "$XRAY_USER")
echo "Xray 服务运行身份：${XRAY_USER}:${XRAY_GROUP}"

# 选择 SNI
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

echo "请选择 Reality 目标域名/SNI："
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

# 检查目标站点从本机是否可达；用户确认后可继续
if ! curl -sSIL --max-time 8 "https://${SNI}/" >/dev/null; then
  echo "⚠️ 服务器无法通过 HTTPS 访问 https://${SNI}/，该目标可能不可达。"
  read -r -p "仍继续？[y/N] " CONTINUE
  [[ "$CONTINUE" =~ ^[Yy]$ ]] || fail "已取消，请选择服务器可访问的目标。"
fi

# 生成 X25519 密钥，识别 Xray 常见输出格式
KEYS_OUT=$("$XRAY_BIN" x25519 2>&1) || fail "Xray 密钥生成失败：$KEYS_OUT"
PRIVATE=$(printf '%s\n' "$KEYS_OUT" | awk -F ': *' 'tolower($1) ~ /private/ {print $NF; exit}')
PUBLIC=$(printf '%s\n' "$KEYS_OUT" | awk -F ': *' 'tolower($1) ~ /public/ {print $NF; exit}')
[[ -n "$PRIVATE" && -n "$PUBLIC" ]] || fail "无法识别 Xray 密钥输出格式：$KEYS_OUT"

# 随机节点参数、公网地址
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORTID=$(openssl rand -hex 8)
IP=""
for url in https://api.ipify.org https://ifconfig.me/ip https://ip.sb; do
  IP=$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)
  [[ -n "$IP" ]] && break
done
if [[ -z "$IP" ]]; then
  read -r -p "无法自动获取公网 IP，请手动输入服务器公网 IP/域名: " IP
fi
[[ -n "$IP" ]] || fail "服务器公网 IP/域名不能为空。"

# 准备目录。临时文件也必须以 .json 结尾，否则 Xray 可能无法识别格式。
# 目录允许服务组遍历，配置文件仅服务用户/组可读。
install -d -o root -g "$XRAY_GROUP" -m 750 "$CONFIG_DIR"
TMP_CONFIG=$(mktemp "$CONFIG_DIR/config.XXXXXX.json")
BACKUP=""
cleanup() { rm -f "${TMP_CONFIG:-}"; }
trap cleanup EXIT

cat >"$TMP_CONFIG" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": $PORT,
    "protocol": "vless",
    "settings": {
      "clients": [{ "id": "$UUID", "flow": "xtls-rprx-vision" }],
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
chown root:"$XRAY_GROUP" "$TMP_CONFIG"
chmod 640 "$TMP_CONFIG"
"$XRAY_BIN" run -test -config "$TMP_CONFIG" || fail "配置校验失败；现有正式配置未被覆盖。"

# 备份并原子替换配置
if [[ -f "$CONFIG_FILE" ]]; then
  BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$CONFIG_FILE" "$BACKUP"
fi
install -o root -g "$XRAY_GROUP" -m 640 "$TMP_CONFIG" "$CONFIG_FILE"

# 检查服务能否重启；失败时输出日志并尽力恢复旧配置
systemctl daemon-reload
systemctl enable xray.service >/dev/null
if ! systemctl restart xray.service; then
  echo "❌ Xray 重启失败，最近日志：" >&2
  journalctl -u xray.service -n 80 --no-pager >&2 || true
  if [[ -n "$BACKUP" ]]; then
    cp -a "$BACKUP" "$CONFIG_FILE"
    systemctl restart xray.service || true
    echo "已尝试恢复旧配置：$BACKUP" >&2
  fi
  fail "服务启动失败。"
fi
sleep 2
if ! systemctl is-active --quiet xray.service; then
  journalctl -u xray.service -n 80 --no-pager >&2 || true
  if [[ -n "$BACKUP" ]]; then
    cp -a "$BACKUP" "$CONFIG_FILE"
    systemctl restart xray.service || true
    echo "已尝试恢复旧配置：$BACKUP" >&2
  fi
  fail "服务未处于 active 状态。"
fi

# 用服务身份验证最终配置确实可读且有效
if ! runuser -u "$XRAY_USER" -- "$XRAY_BIN" run -test -config "$CONFIG_FILE"; then
  echo "❌ 服务用户无法读取或校验正式配置。目录/文件权限如下：" >&2
  namei -l "$CONFIG_FILE" >&2 || true
  journalctl -u xray.service -n 50 --no-pager >&2 || true
  fail "配置以服务用户校验失败。"
fi

# UFW 规则仅覆盖本机防火墙，不会修改云厂商安全组
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" || echo "⚠️ UFW 放行失败，请手动放行 TCP $PORT。" >&2
fi

if ss -lntH "sport = :$PORT" | grep -q .; then
  echo "✅ TCP $PORT 正在本机监听。"
else
  echo "❌ 服务 active 但端口 $PORT 未监听，最近日志：" >&2
  journalctl -u xray.service -n 80 --no-pager >&2 || true
  fail "端口监听检查失败。"
fi

LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC}&sid=${SHORTID}&type=tcp#Reality_${SNI}"
echo
echo "✅ 部署完成：配置校验通过、服务用户可读、服务 active、TCP 端口本机监听。"
echo "注意：这仍不能代替公网连通性测试。务必在云厂商安全组/网络 ACL 放行入站 TCP $PORT。"
echo "--------------------------------"
echo "服务器地址: $IP"
echo "端口: $PORT/TCP"
echo "UUID: $UUID"
echo "公钥 (pbk): $PUBLIC"
echo "Short ID (sid): $SHORTID"
echo "SNI: $SNI"
echo "服务运行身份: ${XRAY_USER}:${XRAY_GROUP}"
echo "配置文件: $CONFIG_FILE（权限 640）"
[[ -n "$BACKUP" ]] && echo "旧配置备份: $BACKUP"
echo "--------------------------------"
echo "VLESS 链接（含访问凭据，请勿公开）:"
echo "$LINK"
echo "--------------------------------"
echo "从另一台机器测试端口：nc -vz $IP $PORT"
