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

# 启用 TCP BBR 与 fq；若当前内核不提供 BBR，则明确提示并继续安装代理。
modprobe tcp_bbr 2>/dev/null || true
if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | tr ' ' '\n' | grep -qx bbr; then
  cat >/etc/sysctl.d/99-singbox-bbr-fq.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL
  sysctl -p /etc/sysctl.d/99-singbox-bbr-fq.conf >/dev/null
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" && "$(sysctl -n net.core.default_qdisc)" == "fq" ]]; then
    echo "TCP BBR 与 fq 已启用并写入持久化配置。"
  else
    echo "警告：已写入 BBR/fq 配置，但内核未能应用；请检查内核支持。" >&2
  fi
else
  echo "警告：当前内核未提供 BBR，跳过 BBR/fq 设置；sing-box 安装继续。" >&2
fi

# 从 GitHub Releases API 获取 latest 稳定版（排除 alpha/beta/rc 预发布）
LATEST_TAG="$(curl -fsSL --retry 3 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -er '.tag_name')"
LATEST_VERSION="${LATEST_TAG#v}"
if [[ ! "$LATEST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "无法识别 GitHub 返回的 sing-box 版本标签：$LATEST_TAG" >&2
  exit 1
fi
echo "将安装 sing-box 最新稳定版：${LATEST_TAG}"

# 官方安装脚本安装指定版本；版本号由上方 API 请求动态获取
curl -fsSL --retry 3 https://sing-box.app/install.sh | sh -s -- --version "$LATEST_VERSION"
command -v sing-box >/dev/null 2>&1 || { echo "sing-box 安装失败。" >&2; exit 1; }

# Reality 的 SNI 同时作为服务端握手目标；允许从候选列表手动选择，
# 直接回车则随机选择。SNI_CHOICE=编号 可用于非交互部署。
# 候选标准（2026-11 真机实测）：冷门站点 + 非 Cloudflare 托管 + TLS 1.3 与 ALPN h2，
# 且已通过 sing-box 服务端+客户端成对实测（generate_204）——仅过 openssl 静态
# 检查的站点（如 swinburne/han.nl）实际握手会被对方前端拒绝，故不在此列。
# 注意：CDN 托管会变，站点可能迁入 Cloudflare 或降级 TLS；脚本在选定后还会再做一次握手校验。
SNI_OPTIONS=(
  "www.rp.edu.sg" "www.ite.edu.sg" "www.nyp.edu.sg"
  "www.tp.edu.sg" "creative.com" "www.lovelive-anime.jp"
  "www.ru.nl" "global.fujifilm.com" "www.fom-international.com"
  "vuejs-jp.org" "zh-hk.vuejs.org" "www.avans.nl"
  "www.utwente.nl" "www.curtin.edu.au" "www.westernsydney.edu.au"
  "www.dcu.ie" "www.ul.ie" "www.uea.ac.uk"
  "www.kyushu-u.ac.jp"
)

SNI_CHOICE="${SNI_CHOICE:-}"
if [[ -z "$SNI_CHOICE" && -t 0 ]]; then
  echo "请选择 Reality SNI（伪装域名）："
  for i in "${!SNI_OPTIONS[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${SNI_OPTIONS[$i]}"
  done
  read -r -p "输入编号；直接回车随机选择：" SNI_CHOICE
fi
if [[ -z "$SNI_CHOICE" ]]; then
  SNI_INDEX="$(shuf -i 0-$((${#SNI_OPTIONS[@]} - 1)) -n 1)"
elif [[ "$SNI_CHOICE" =~ ^[0-9]+$ ]] && (( SNI_CHOICE >= 1 && SNI_CHOICE <= ${#SNI_OPTIONS[@]} )); then
  SNI_INDEX="$((SNI_CHOICE - 1))"
else
  echo "SNI_CHOICE 必须是 1 到 ${#SNI_OPTIONS[@]} 的编号。" >&2
  exit 1
fi
TARGET="${SNI_OPTIONS[$SNI_INDEX]}"
echo "已选择 SNI：${TARGET}；正在检查其 TLS 1.3 与 ALPN h2 支持……"
# Reality 握手目标必须同时支持 TLS 1.3 与 ALPN h2；只支持 TLS 1.3 的站点
# （例如无 h2 的直连源站）会导致客户端连接失败，故在此一并校验 h2。
SNI_PROBE="$(timeout 10 openssl s_client -connect "${TARGET}:443" -servername "$TARGET" -tls1_3 -alpn h2 </dev/null 2>/dev/null || true)"
if ! grep -q "ALPN protocol: h2" <<<"$SNI_PROBE"; then
  echo "无法与 ${TARGET}:443 完成 TLS 1.3 + h2 握手。请重跑并选择其他 SNI 编号。" >&2
  exit 1
fi

# 端口、UUID 和密钥随机生成；short_id 遵守 Reality 最多 8 位的限制。
PORT="$(shuf -i 20000-55000 -n 1)"
UUID="$(cat /proc/sys/kernel/random/uuid)"
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
