#!/usr/bin/env bash
#
# install-port-forward.sh
#
# 一键脚本示例：自动更新系统、安装 nftables，并配置端口转发 (TCP/UDP)。
# 支持 Debian/Ubuntu 系统。
#
# 使用方法：
#   1. chmod +x install-port-forward.sh
#   2. sudo ./install-port-forward.sh
#
# 注意：若已有 /etc/nftables.conf 规则，脚本会覆盖其所在 table 的规则！

set -e  # 脚本遇到错误时立即退出

echo "===================================================================="
echo "  [脚本说明] 这将会："
echo "   1) 更新系统包 (apt update && apt dist-upgrade -y)"
echo "   2) 安装并启用 nftables"
echo "   3) 询问端口转发相关信息 (本机端口、目标IP、目标端口)"
echo "   4) 启用 IP 转发，写入 /etc/nftables.conf 并加载规则"
echo "   5) (可选) 检测并放行 UFW 的入站端口"
echo "===================================================================="
echo

#=== 变量定义 =========================================================
NFTABLES_CONF="/etc/nftables.conf" # 默认的 nftables 配置文件路径
TABLE_NAME="port_forwarding"        # nftables 表名

#=== 检查系统是否为 Debian/Ubuntu ========================================
if [ -f /etc/debian_version ]; then
  echo "[检测] 系统为 Debian/Ubuntu，继续执行。"
else
  echo "[错误] 本脚本仅适用于 Debian/Ubuntu 系统，退出。"
  exit 1
fi

#=== 更新系统 ============================================================
echo
echo "[1/6] 更新系统 (apt update & dist-upgrade) ..."
sudo apt update
sudo apt dist-upgrade -y

#=== 安装 nftables =======================================================
echo
echo "[2/6] 安装 nftables ..."
sudo apt install -y nftables
sudo systemctl enable nftables
sudo systemctl start nftables

#=== 询问端口与 IP，进行用户交互 ========================================
echo
echo "[3/6] 请输入端口转发相关信息："

# 1) 本机端口
read -p "  本机端口 (e.g. 2222, 默认: 8080): " LOCAL_PORT
LOCAL_PORT=${LOCAL_PORT:-8080} # 如果用户没有输入，则使用默认值 8080
# 验证端口号
if ! [[ "${LOCAL_PORT}" =~ ^[0-9]+$ ]] || (( LOCAL_PORT < 1 || LOCAL_PORT > 65535 )); then
    echo "[错误] 本机端口必须为 1 到 65535 之间的数字。"
    exit 1
fi

# 2) 目标机器 IP
read -p "  目标机器 IP (e.g. 6.6.6.6, 默认: 127.0.0.1): " TARGET_IP
TARGET_IP=${TARGET_IP:-127.0.0.1} # 如果用户没有输入，则使用默认值 127.0.0.1
# 验证IP地址 (简单示例)
if ! [[ "${TARGET_IP}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
  echo "[错误] 无效的目标IP地址。"
  exit 1
fi

# 3) 目标机器端口
read -p "  目标机器端口 (e.g. 6666, 默认: 80): " TARGET_PORT
TARGET_PORT=${TARGET_PORT:-80} # 如果用户没有输入，则使用默认值 80
# 验证端口号
if ! [[ "${TARGET_PORT}" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
    echo "[错误] 目标机器端口必须为 1 到 65535 之间的数字。"
    exit 1
fi

# 4) 询问是否需要 Masquerade
read -p "  是否需要对目标IP进行 Masquerade (通常不需要，除非目标IP是公网IP且路由未配置)？(y/N): " USE_MASQUERADE
USE_MASQUERADE=${USE_MASQUERADE:-N} # 默认值为 N

#=== 开启内核转发 =======================================================
echo
echo "[4/6] 开启内核 IP 转发 ..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

#=== 写入 /etc/nftables.conf 并加载 =====================================
echo
echo "[5/6] 写入 ${NFTABLES_CONF} 并应用规则 (TCP/UDP) ..."

# 备份原配置（可选）
if [ -f "${NFTABLES_CONF}" ]; then
  sudo cp "${NFTABLES_CONF}" "${NFTABLES_CONF}.bak_$(date +%Y%m%d%H%M%S)"
fi

# 将你的转发规则写入 /etc/nftables.conf
cat <<EOF | sudo tee "${NFTABLES_CONF}"
#!/usr/sbin/nft -f

# 清空 ${TABLE_NAME} 表中的所有规则
flush table ip ${TABLE_NAME}

# 创建 ${TABLE_NAME} 表
table ip ${TABLE_NAME} {

    # 在 prerouting 链中进行 DNAT
    chain prerouting {
        type nat hook prerouting priority -100; policy accept;
        # 转发 TCP 流量 (本机端口: ${LOCAL_PORT}, 目标IP: ${TARGET_IP}, 目标端口: ${TARGET_PORT})
        tcp dport ${LOCAL_PORT} dnat to ${TARGET_IP}:${TARGET_PORT}
        # 转发 UDP 流量 (本机端口: ${LOCAL_PORT}, 目标IP: ${TARGET_IP}, 目标端口: ${TARGET_PORT})
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

#=== 检测并放行 UFW (若存在) ============================================
echo
echo "[6/6] 检测是否有 UFW，并尝试放行本机端口 ${LOCAL_PORT} ..."
if command -v ufw >/dev/null 2>&1; then
  if sudo ufw status | grep -q "Status: active"; then
    echo "  UFW 已安装且已启用，自动放行入站端口..."
    sudo ufw allow "${LOCAL_PORT}"/tcp
    sudo ufw allow "${LOCAL_PORT}"/udp
    echo "  完成放行。"
  else
    echo "  UFW 已安装但未启用，请手动配置规则。"
  fi
else
  echo "  UFW 未检测到或未安装，无需处理。"
fi

echo
echo "===================================================================="
echo "  [完成] nftables 端口转发配置成功！"
echo "  已将本机 :${LOCAL_PORT} -> ${TARGET_IP}:${TARGET_PORT} (TCP/UDP)"
echo
echo "  重启后依然有效，可执行以下命令查看规则："
echo "    sudo nft list ruleset"
echo
echo "===================================================================="
