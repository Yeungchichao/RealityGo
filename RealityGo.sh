#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu 上部署 Xray VLESS + REALITY。需要 root 权限。
XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/xray.service"

fail() { echo "❌ $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "请使用 root 权限运行，例如：sudo bash $0"

# 0. 安装依赖（不以单个依赖是否存在作为安装条件）
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl openssl unzip
else
  need_cmd curl
  need_cmd openssl
fi
need_cmd curl
need_cmd openssl
need_cmd systemctl
need_cmd ss

# 1. 安装 Xray（若不存在或不可执行）
if [[ ! -x "$XRAY_BIN" ]]; then
  echo "正在安装 Xray..."
  bash <(curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh )
fi
[[ -x "$XRAY_BIN" ]] || fail "找不到可执行的 Xray：$XRAY_BIN"

# 2. 选择 SNI
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

echo "请选择 Reality 的目标域名/SNI："
select opt in "${SNI_OPTIONS[@]}"; do
  [[ -n "${opt:-}" ]] || { echo "请输入有效序号。"; continue; }
  if [[ "$opt" == "自定义输入" ]]; then
    read -r -p "请输入域名（不含协议、端口或路径）: " SNI
  else
    SNI="$opt"
  fi
  break
done

# 基础域名格式检查，防止把配置 JSON 注入用户输入
[[ "$SNI" =~ ^[A-Za-z0-9.-]+$ ]] || fail "域名格式不合法：$SNI"
[[ "$SNI" != .* && "$SNI" != *. && "$SNI" != *..* ]] || fail "域名格式不合法：$SNI"

# 3. 检查服务器能否访问所选目标
if ! curl -sSIL --max-time 8 "https://${SNI}/" >/dev/null; then
  echo "⚠️ 服务器无法通过 HTTPS 访问 https://${SNI}/ 。该域名可能不可达或不适合作为 Reality 目标。"
  read -r -p "仍然继续部署？[y/N] " CONTINUE
  [[ "$CONTINUE" =~ ^[Yy]$ ]] || fail "已取消。请改选可从服务器访问的目标域名。"
fi

# 4. 生成密钥并兼容常见 xray 输出标签
KEYS_OUT=$("$XRAY_BIN" x25519 2>&1) || fail "Xray 密钥生成失败：$KEYS_OUT"
PRIVATE=$(printf '%s\n' "$KEYS_OUT" | awk -F ': *' 'tolower($1) ~ /private/ {print $NF; exit}')
PUBLIC=$(printf '%s\n' "$KEYS_OUT" | awk -F ': *' 'tolower($1) ~ /public/ {print $NF; exit}')
[[ -n "$PRIVATE" && -n "$PUBLIC" ]] || fail "无法从 Xray 输出识别密钥格式。原始输出：$KEYS_OUT"

# 5. 参数与公网 IP
PORT=$(shuf -i 20000-60000 -n 1)
UUID=$(cat /proc/sys/kernel/random/uuid)
SHORTID=$(openssl rand -hex 8)
IP=""
for url in https://api.ipify.org https://ifconfig.me/ip https://ip.sb; do
  IP=$(curl -fsS --max-time 5 "$url" 2>/dev/null || true)
  [[ -n "$IP" ]] && break
done
if [[ -z "$IP" ]]; then
  echo "⚠️ 无法自动获取公网 IP。"
  read -r -p "请输入服务器公网 IP 或域名: " IP
fi
[[ -n "$IP" ]] || fail "公网 IP/域名不能为空。"

# 6. 生成配置，先写临时文件并校验，通过后再替换
mkdir -p "$CONFIG_DIR"
TMP_CONFIG=$(mktemp "$CONFIG_DIR/config.json.XXXXXX")
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
chmod 600 "$TMP_CONFIG"
"$XRAY_BIN" run -test -config "$TMP_CONFIG" || fail "Xray 配置校验失败，旧配置未被覆盖。"

# 7. 备份旧配置后安装新配置
if [[ -f "$CONFIG_FILE" ]]; then
  BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "$CONFIG_FILE" "$BACKUP"
fi
install -o root -g root -m 600 "$TMP_CONFIG" "$CONFIG_FILE"

# 确保存在 systemd 服务；官方安装脚本通常会创建该服务
if ! systemctl cat xray.service >/dev/null 2>&1 && [[ ! -f "$SERVICE_FILE" ]]; then
  fail "未找到 xray.service。Xray 已安装但 systemd 服务缺失，请检查官方安装脚本输出。配置已写入：$CONFIG_FILE"
fi
systemctl daemon-reload
systemctl enable xray >/dev/null
if ! systemctl restart xray; then
  echo "❌ Xray 重启失败，最近日志：" >&2
  journalctl -u xray -n 60 --no-pager >&2 || true
  [[ -n "$BACKUP" ]] && { cp -a "$BACKUP" "$CONFIG_FILE"; systemctl restart xray || true; echo "已尝试恢复旧配置：$BACKUP" >&2; }
  fail "服务启动失败。"
fi
sleep 1
if ! systemctl is-active --quiet xray; then
  journalctl -u xray -n 60 --no-pager >&2 || true
  [[ -n "$BACKUP" ]] && { cp -a "$BACKUP" "$CONFIG_FILE"; systemctl restart xray || true; echo "已尝试恢复旧配置：$BACKUP" >&2; }
  fail "Xray 服务未处于 active 状态。"
fi

# 8. 放行本机 UFW（如已启用）；云厂商安全组仍需手动放行
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" || echo "⚠️ UFW 放行失败，请手动放行 TCP $PORT。" >&2
fi

if ! ss -lntH "sport = :$PORT" | grep -q .; then
  echo "⚠️ 服务显示 active，但 ss 未检测到端口 $PORT 监听；请检查日志。" >&2
  journalctl -u xray -n 40 --no-pager >&2 || true
fi

# 9. 输出节点参数与客户端链接
LINK="vless://${UUID}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC}&sid=${SHORTID}&type=tcp#Reality_${SNI}"
echo
echo "✅ 部署完成并通过服务状态检查。"
echo "--------------------------------"
echo "服务器地址: $IP"
echo "端口: $PORT/TCP"
echo "UUID: $UUID"
echo "公钥 (pbk): $PUBLIC"
echo "Short ID (sid): $SHORTID"
echo "SNI: $SNI"
echo "配置文件: $CONFIG_FILE"
[[ -n "$BACKUP" ]] && echo "旧配置备份: $BACKUP"
echo "--------------------------------"
echo "VLESS 链接（请妥善保管，含访问凭据）:"
echo "$LINK"
echo "--------------------------------"
echo "重要：请在云厂商安全组/防火墙放行入站 TCP $PORT；本脚本无法自动修改云安全组。"
echo "远程测试示例：nc -vz $IP $PORT"
