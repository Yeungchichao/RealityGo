#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box VLESS + Reality 一键安装脚本（Debian/Ubuntu）
# 用法：sudo bash singbox-vless-reality.sh [公网IPv4或域名]
# 若不传地址，尝试自动探测公网 IPv4；探测失败时需重新传入地址。

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash $0 [公网IP或域名]" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "此脚本仅支持 Debian/Ubuntu 系统（需要 apt-get）。" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl jq openssl
getent group sing-box >/dev/null 2>&1 || groupadd --system sing-box

# 官方手动安装脚本（Debian/Ubuntu 会安装对应的软件包并提供 systemd 服务）
curl -fsSL https://sing-box.app/install.sh | sh
command -v sing-box >/dev/null 2>&1 || { echo "sing-box 安装失败。" >&2; exit 1; }

# 所有可随机的连接参数均随机生成。Reality 伪装目标必须是可用的真实 TLS 站点，
# 因此从候选公开域名中随机选择，而不是使用不存在的随机域名。
PORT="$(shuf -i 20000-55000 -n 1)"
UUID="$(cat /proc/sys/kernel/random/uuid)"
TARGET="$(printf '%s\n' www.microsoft.com www.apple.com www.samsung.com www.adobe.com www.amazon.com | shuf -n 1)"
# sing-box Reality short_id 最多 8 个十六进制字符；4 随机字节正好 8 位。
SHORT_ID="$(openssl rand -hex 4)"
KEY_OUTPUT="$(sing-box generate reality-keypair)"
PRIVATE_KEY="$(awk -F': ' '/PrivateKey:/ {print $2}' <<<"$KEY_OUTPUT" | tr -d '\r')"
PUBLIC_KEY="$(awk -F': ' '/PublicKey:/ {print $2}' <<<"$KEY_OUTPUT" | tr -d '\r')"

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
  echo "无法从 sing-box 生成结果中解析 Reality 密钥对：" >&2
  echo "$KEY_OUTPUT" >&2
  exit 1
fi

# 取得客户端连接地址；用户可传入公网 IP / 域名，避免错误的自动探测结果。
SERVER_ADDR="${1:-}"
if [[ -z "$SERVER_ADDR" ]]; then
  SERVER_ADDR="$(curl -4fsS --max-time 8 https://api.ipify.org || true)"
fi
if [[ -z "$SERVER_ADDR" ]]; then
  echo "无法自动获取公网 IPv4。请重新执行：sudo bash $0 <公网IPv4或域名>" >&2
  exit 1
fi

install -d -m 0755 /etc/sing-box
STAMP="$(date +%Y%m%d%H%M%S)"
if [[ -f /etc/sing-box/config.json ]]; then
  cp -a /etc/sing-box/config.json "/etc/sing-box/config.json.bak.${STAMP}"
fi

TMP_CONFIG="$(mktemp)"
cat >"$TMP_CONFIG" <<JSON
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
      "listen_port": ${PORT},
      "users": [
        {
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${TARGET}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${TARGET}",
            "server_port": 443
          },
          "private_key": "${PRIVATE_KEY}",
          "short_id": ["${SHORT_ID}"]
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
JSON

# 验证配置后再替换生效文件
sing-box check -c "$TMP_CONFIG"
# 新版官方 systemd 服务可能以低权限用户运行；让服务通过专用组读取配置，
# 同时避免将 Reality 私钥设为全系统用户可读。
install -o root -g sing-box -m 0640 "$TMP_CONFIG" /etc/sing-box/config.json
rm -f "$TMP_CONFIG"

install -d -m 0755 /etc/systemd/system/sing-box.service.d
cat >/etc/systemd/system/sing-box.service.d/10-config-access.conf <<'UNIT'
[Service]
SupplementaryGroups=sing-box
ExecStart=
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
UNIT
systemctl daemon-reload

# 允许服务开机自启并立即启动
systemctl enable sing-box
systemctl restart sing-box
sleep 1
if ! systemctl is-active --quiet sing-box; then
  journalctl -u sing-box -n 80 --no-pager >&2 || true
  echo "sing-box 未能启动，请检查上方日志。" >&2
  exit 1
fi
if ! ss -H -lnt "sport = :${PORT}" 2>/dev/null | grep -q .; then
  journalctl -u sing-box -n 80 --no-pager >&2 || true
  echo "服务虽然处于 active 状态，但未监听预期端口 ${PORT}。请检查 systemd 配置和日志。" >&2
  ss -lntp >&2 || true
  exit 1
fi

# 若存在 UFW，尝试放行 TCP 端口。云厂商安全组仍需在控制台另行放行。
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" || true
fi

CLIENT_FILE="/root/sing-box-client.json"
cat >"$CLIENT_FILE" <<JSON
{
  "log": {"level": "info"},
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 2080
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "${SERVER_ADDR}",
      "server_port": ${PORT},
      "uuid": "${UUID}",
      "flow": "xtls-rprx-vision",
      "tls": {
        "enabled": true,
        "server_name": "${TARGET}",
        "utls": {"enabled": true, "fingerprint": "chrome"},
        "reality": {
          "enabled": true,
          "public_key": "${PUBLIC_KEY}",
          "short_id": "${SHORT_ID}"
        }
      }
    }
  ],
  "route": {"final": "proxy"}
}
JSON
chmod 600 "$CLIENT_FILE"

# 同时生成常见代理客户端可导入的 VLESS URI。
URI_SERVER_ADDR="$SERVER_ADDR"
if [[ "$URI_SERVER_ADDR" == *:* && "$URI_SERVER_ADDR" != \[*\] ]]; then
  URI_SERVER_ADDR="[$URI_SERVER_ADDR]"
fi
VLESS_URI="vless://${UUID}@${URI_SERVER_ADDR}:${PORT}?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#sing-box-reality"
LINK_FILE="/root/sing-box-vless-link.txt"
printf '%s\n' "$VLESS_URI" >"$LINK_FILE"
chmod 600 "$LINK_FILE"

printf '\n部署成功。\n'
printf '服务器地址：%s\n端口：%s\n伪装域名：%s\nUUID：%s\nReality 公钥：%s\nShort ID：%s\n' \
  "$SERVER_ADDR" "$PORT" "$TARGET" "$UUID" "$PUBLIC_KEY" "$SHORT_ID"
printf '\n客户端 sing-box 配置：%s\n' "$CLIENT_FILE"
printf 'VLESS 导入链接文件：%s\n' "$LINK_FILE"
printf 'VLESS 节点链接（含 UUID 凭据，请勿公开）：\n%s\n' "$VLESS_URI"
printf '服务状态：systemctl status sing-box\n'
printf '注意：请在 VPS/云厂商安全组放行 TCP %s；该端口是随机生成的。\n' "$PORT"
printf '服务端配置：/etc/sing-box/config.json（含私钥，请勿公开）\n'
