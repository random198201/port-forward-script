#!/usr/bin/env bash
#
# auto-port-forward.sh
#
# 自动配置端口转发 (TCP/UDP)。
# 支持 Debian/Ubuntu 系统, 且已安装 nftables。
#
# 使用方法：
#   1. chmod +x auto-port-forward.sh
#   2. sudo ./auto-port-forward.sh
#

set -e

#=== 变量定义 =========================================================
NFTABLES_CONF="/etc/nftables.conf"  # nftables 配置文件路径
TABLE_NAME="auto_port_forwarding"     # nftables 表名

#=== 默认值 ==========================================================
DEFAULT_LOCAL_PORT="8080"
DEFAULT_TARGET_IP="127.0.0.1"
DEFAULT_TARGET_PORT="80"

#=== 获取本机 IP =======================================================
LOCAL_IP=$(ip -4 route get 8.8.8.8 | awk '{print $7; exit}')

#=== 提示用户输入参数 ================================================
echo "===================================================================="
echo "  [脚本说明] 这将会配置端口转发规则。"
echo "===================================================================="
echo

# 1) 本机端口
read -p "  本机端口 (默认: ${DEFAULT_LOCAL_PORT}): " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-${DEFAULT_LOCAL_PORT}}
if ! [[ "${LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( LOCAL_PORT < 1 || LOCAL_PORT > 65535 )); then
    echo "[错误] 本机端口必须为 1 到 65535 之间的数字。"
    exit 1
fi

# 2) 目标机器 IP
read -p "  目标机器 IP (默认: ${DEFAULT_TARGET_IP}): " TARGET_IP
TARGET_IP=${TARGET_IP:-${DEFAULT_TARGET_IP}}
if ! [[ "${TARGET_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "[错误] 无效的目标IP地址。"
  exit 1
fi

# 3) 目标机器端口
read -p "  目标机器端口 (默认: ${DEFAULT_TARGET_PORT}): " TARGET_PORT
TARGET_PORT=${TARGET_PORT:-${DEFAULT_TARGET_PORT}}
if ! [[ "${TARGET_PORT}" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
    echo "[错误] 目标机器端口必须为 1 到 65535 之间的数字。"
    exit 1
fi

# 4) 询问是否需要 Masquerade
read -p "  是否需要对目标IP进行 Masquerade (通常不需要，除非目标IP是公网IP且路由未配置)？(y/N): " USE_MASQUERADE
USE_MASQUERADE=${USE_MASQUERADE:-N}

#=== 开启内核转发 =======================================================
echo
echo "[1/3] 开启内核 IP 转发 ..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

#=== 写入 /etc/nftables.conf 并加载 =====================================
echo
echo "[2/3] 写入 ${NFTABLES_CONF} 并应用规则 (TCP/UDP) ..."

# 备份原配置（可选）
if [ -f "${NFTABLES_CONF}" ]; then
  sudo cp "${NFTABLES_CONF}" "${NFTABLES_CONF}.bak_$(date +%Y%m%d%H%M%S)"
fi

cat <<EOF | sudo tee "${NFTABLES_CONF}"
#!/usr/sbin/nft -f

# 清空 ${TABLE_NAME} 表中的所有规则
flush table ip ${TABLE_NAME}

# 创建 ${TABLE_NAME} 表
table ip ${TABLE_NAME} {

    # 在 prerouting 链中进行 DNAT
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        # 转发 TCP 流量 (本机IP: ${LOCAL_IP}, 本机端口: ${LOCAL_PORT}, 目标IP: ${TARGET_IP}, 目标端口: ${TARGET_PORT})
        tcp dport ${LOCAL_PORT} dnat to ${TARGET_IP}:${TARGET_PORT}
        # 转发 UDP 流量 (本机IP: ${LOCAL_IP}, 本机端口: ${LOCAL_PORT}, 目标IP: ${TARGET_IP}, 目标端口: ${TARGET_PORT})
        udp dport ${LOCAL_PORT} dnat to ${TARGET_IP}:${TARGET_PORT}
    }

    # 在 postrouting 链中进行 Masquerade (可选)
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
EOF

if [[ "${USE_MASQUERADE}" =~ ^[Yy]$ ]]; then
  echo "        # 对目标IP ${TARGET_IP} 进行 Masquerade" >> "${NFTABLES_CONF}"
  echo "        ip daddr ${TARGET_IP} masquerade" >> "${NFTABLES_CONF}"
fi

cat <<EOF >> "${NFTABLES_CONF}"
    }
}
EOF

# 加载新规则
sudo nft -f "${NFTABLES_CONF}"

echo
echo "[3/3] 完成!"
echo "===================================================================="
echo "  [完成] nftables 端口转发配置成功！"
echo "  已将本机 ${LOCAL_IP}:${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT} (TCP/UDP)"
echo "  重启后依然有效，可执行以下命令查看规则："
echo "    sudo nft list ruleset"
echo "===================================================================="
