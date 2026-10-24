#!/usr/bin/env bash
# VLESS + REALITY + 443 一键部署
#
# 用法：
#   sudo bash reality-install.sh
#   sudo SNI=www.apple.com bash reality-install.sh      # 换伪装站
#
# 支持：Ubuntu 22.04/24.04、Debian 12
# 特点：只用 443、无需域名证书、伪装成真实大站、开 BBR
#
# 注意：云厂商安全组必须放行入站 TCP 443，这是脚本无法代劳的一步。
set -euo pipefail

SNI="${SNI:-www.microsoft.com}"
DEST="${DEST:-${SNI}:443}"
PORT="${PORT:-443}"
CONF="/usr/local/etc/xray/config.json"

echo "==> 1/6 安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y curl openssl uuid-runtime >/dev/null

echo "==> 2/6 安装 Xray"
if ! command -v xray >/dev/null 2>&1; then
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
fi
# 注意 || true：head 关闭管道会让 xray 收到 SIGPIPE，配合 pipefail 会静默终止整个脚本
xray version 2>/dev/null | head -1 || true

echo "==> 3/6 生成密钥 / UUID / shortId"
KEYS=$(xray x25519)
# Xray 26 输出：PrivateKey / Password (PublicKey) / Hash32
# Xray 1.8 输出：Private key / Public key
PRIV=$(echo "$KEYS" | awk '/[Pp]rivate ?[Kk]ey/{print $NF}')
PUB=$(echo "$KEYS" | awk '/[Pp]assword|[Pp]ublic ?[Kk]ey/{print $NF}' | tail -1)
UUID=$(xray uuid)
SHORTID=$(openssl rand -hex 8)
if [ -z "$PRIV" ] || [ -z "$PUB" ]; then
  echo "!! 密钥解析失败，xray x25519 输出格式可能变了："
  echo "$KEYS"
  exit 1
fi

echo "==> 4/6 写配置"
mkdir -p "$(dirname "$CONF")"
cat > "$CONF" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${DEST}",
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIV}",
          "shortIds": [ "${SHORTID}" ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ]
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": [ "geoip:private" ], "outboundTag": "block" },
      { "type": "field", "protocol": [ "bittorrent" ], "outboundTag": "block" }
    ]
  }
}
JSON

# 配置写入校验：写失败或为空时立刻停下，不要留一个 active 但不可用的服务
SIZE=$(stat -c %s "$CONF" 2>/dev/null || echo 0)
if [ "$SIZE" -lt 300 ]; then
  echo "!! 配置只写了 ${SIZE} 字节，明显不完整，中止"
  exit 1
fi

echo "==> 5/6 启动服务"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
systemctl --no-pager --lines=0 status xray | head -5 || true

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  echo "    ufw 已放行 ${PORT}/tcp"
fi

echo "==> 6/6 开启 BBR（可选）"
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf 2>/dev/null; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1 || true
fi

IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "<你的服务器IP>")

cat <<OUT

============================================================
部署完成。客户端参数：
------------------------------------------------------------
  address:     ${IP}
  port:        ${PORT}
  uuid:        ${UUID}
  flow:        xtls-rprx-vision
  network:     tcp
  tls:         true
  servername:  ${SNI}
  public-key:  ${PUB}
  short-id:    ${SHORTID}

  节点链接：
  vless://${UUID}@${IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SHORTID}&type=tcp&flow=xtls-rprx-vision#reality-443
============================================================
检查清单：
1. 云安全组放行入站 TCP ${PORT}（默认只开 22/80）
2. 验证监听：sudo ss -ltnp | grep ${PORT}
3. 验证握手：openssl s_client -connect ${IP}:${PORT} -servername ${SNI} </dev/null 2>/dev/null | head -5
4. 看日志：sudo journalctl -u xray -n 50 --no-pager
OUT
