#!/usr/bin/env bash
set -Eeuo pipefail

# sing-box 一键卸载脚本（Debian/Ubuntu）
# 用法：sudo bash singbox-uninstall.sh
# 卸载由 singbox-vless-reality.sh 或官方 .deb 安装的 sing-box：
# 停止并禁用服务、移除软件包/二进制、配置与状态目录、专用用户/组。
# 配置与客户端文件会先打包备份到 /root，确认无误后可手动删除备份。

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 运行：sudo bash $0" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d%H%M%S)"
BACKUP="/root/sing-box-backup-${STAMP}.tgz"

# 若还有其他 sing-box 实例（如 sing-box-reality / sing-box-ss），直接停下不动手。
# 这些实例共用 /usr/bin/sing-box 或 /usr/local/bin/sing-box 这同一个二进制，
# 只警告却继续 purge / 删二进制会把它们一起弄停，所以必须先停在这里。
OTHER_SERVICES="$(systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^sing-box-.+\.service$' || true)"
if [[ -n "$OTHER_SERVICES" ]]; then
  echo "已停止，未卸载任何东西。发现其他 sing-box 实例与主服务共用同一个二进制：" >&2
  echo "$OTHER_SERVICES" | sed 's/^/  - /' >&2
  echo "先停掉并确认不再需要这些实例（或改用只删配置的手动方式），再重跑本脚本。" >&2
  exit 1
fi

# 读取节点端口（若配置还在），用于随后清理 UFW 放行规则。
PORT=""
if [[ -f /etc/sing-box/config.json ]] && command -v jq >/dev/null 2>&1; then
  PORT="$(jq -r '.inbounds[0].listen_port // empty' /etc/sing-box/config.json 2>/dev/null || true)"
fi

# 备份配置与客户端凭据文件（内含私钥/链接，备份文件权限 600）。
BACKUP_ITEMS=()
[[ -d /etc/sing-box ]] && BACKUP_ITEMS+=("/etc/sing-box")
[[ -f /root/sing-box-client.json ]] && BACKUP_ITEMS+=("/root/sing-box-client.json")
[[ -f /root/sing-box-vless-link.txt ]] && BACKUP_ITEMS+=("/root/sing-box-vless-link.txt")
if [[ ${#BACKUP_ITEMS[@]} -gt 0 ]]; then
  tar -czf "$BACKUP" "${BACKUP_ITEMS[@]}" 2>/dev/null || true
  chmod 600 "$BACKUP" 2>/dev/null || true
  echo "已备份到：$BACKUP"
fi

echo "正在停止并禁用 sing-box 服务……"
systemctl stop sing-box 2>/dev/null || true
systemctl disable sing-box 2>/dev/null || true

echo "正在移除 sing-box……"
if dpkg -l sing-box >/dev/null 2>&1; then
  # 官方 .deb 安装：连同包内配置文件一并清除。
  apt-get purge -y sing-box || true
fi
# 兜底清理可能残留的二进制与手动安装痕迹。
rm -f /usr/bin/sing-box /usr/local/bin/sing-box

rm -rf /etc/sing-box \
       /var/lib/sing-box \
       /etc/systemd/system/sing-box.service.d \
       /root/sing-box-client.json \
       /root/sing-box-vless-link.txt
systemctl daemon-reload
systemctl reset-failed sing-box 2>/dev/null || true

# 删除专用用户/组（若被其他残留服务占用则 userdel 会失败，忽略即可）。
userdel sing-box 2>/dev/null || true
groupdel sing-box 2>/dev/null || true

# 清理安装脚本写入的 UFW 放行规则（云厂商安全组需在控制台另行关闭）。
if [[ -n "$PORT" ]] && command -v ufw >/dev/null 2>&1; then
  ufw delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
  echo "已删除 UFW 放行规则：${PORT}/tcp"
fi

echo
echo "卸载完成。校验："
FAIL=0
if pgrep -x sing-box >/dev/null 2>&1; then echo "  ✗ sing-box 进程仍在运行"; FAIL=1; else echo "  ✓ 无 sing-box 进程"; fi
if command -v sing-box >/dev/null 2>&1; then echo "  ✗ sing-box 命令仍存在"; FAIL=1; else echo "  ✓ sing-box 命令已移除"; fi
if [[ -n "$PORT" ]] && ss -H -lnt "sport = :${PORT}" 2>/dev/null | grep -q .; then echo "  ✗ 端口 ${PORT} 仍在监听"; FAIL=1; elif [[ -n "$PORT" ]]; then echo "  ✓ 端口 ${PORT} 已无监听"; fi
echo "  备份文件：${BACKUP}（确认不再需要后可删除）"
echo "  说明：安装脚本写入的 BBR/fq 配置（/etc/sysctl.d/99-singbox-bbr-fq.conf）已保留，未改动系统网络参数。"
[[ "$FAIL" -eq 0 ]] || echo "  注意：存在未清理干净的项目，请按上方 ✗ 检查。"
