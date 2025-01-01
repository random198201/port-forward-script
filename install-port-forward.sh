#!/usr/bin/env bash
#
# install-port-forward.sh
#
# 一键脚本示例：自动更新系统、安装 nftables，并配置端口转发 (TCP/UDP)。
# 支持 Debian/Ubuntu 系统。
#
# 使用方法：
#   1. chmod +x install-port-forward.sh
#   2. sudo ./install-port-forward.sh
#
# 注意：若已有 /etc/nftables.conf 规则，脚本会覆盖之！

set -e

echo "===================================================================="
echo "  [脚本说明] 这将会："
echo "   1) 更新系统包 (apt update && apt dist-upgrade -y)"
echo "   2) 安装并启用 nftables"
echo "   3) 询问端口转发相关信息 (本机端口、目标IP、目标端口)"
echo "   4) 启用 IP 转发，写入 /etc/nftables.conf 并加载规则"
echo "   5) (可选) 检测并放行 UFW 的入站端口"
echo "===================================================================="
echo

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

#=== 询问端口与 IP，增加简单的合法性检查 ===============================

# 1) 询问本机端口 (LOCAL_PORT)
echo
echo "[3/6] 请输入端口转发相关信息："
while true; do
  read -p "  本机端口 (1-65535, 例如 2222): " LOCAL_PORT
  # 检查是否为数字 + 范围
  if [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && [ "$LOCAL_PORT" -ge 1 ] && [ "$LOCAL_PORT" -le 65535 ]; then
    break
  else
    echo "  [错误] 端口输入不合法，请重新输入。"
  fi
done

# 2) 询问目标机器 IP (TARGET_IP)
#   这里仅做最简单的“4段0-255”检查，无法百分百判断合法IP，但能基本避免明显错误
while true; do
  read -p "  目标机器 IP (例如 6.6.6.6): " TARGET_IP
  if [[ "$TARGET_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    # 进一步检查每段是否在0-255
    VALID_IP="true"
    IFS='.' read -r -a ip_parts <<< "$TARGET_IP"
    for part in "${ip_parts[@]}"; do
      if [ "$part" -lt 0 ] || [ "$part" -gt 255 ]; then
        VALID_IP="false"
        break
      fi
    done
    if [ "$VALID_IP" = "true" ]; then
      break
    else
      echo "  [错误] IP 段超出 0-255 范围，请重新输入。"
    fi
  else
    echo "  [错误] IP 格式不正确，请重新输入。"
  fi
done

# 3) 询问目标机器端口 (TARGET_PORT)
while true; do
  read -p "  目标机器端口 (1-65535, 例如 6666): " TARGET_PORT
  if [[ "$TARGET_PORT" =~ ^[0-9]+$ ]] && [ "$TARGET_PORT" -ge 1 ] && [ "$TARGET_PORT" -le 65535 ]; then
    break
  else
    echo "  [错误] 端口输入不合法，请重新输入。"
  fi
done

#=== 开启内核转发 =======================================================
echo
echo "[4/6] 开启内核 IP 转发 ..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi
sudo sysctl -p

#=== 写入 /etc/nftables.conf 并加载 =====================================
echo
echo "[5/6] 写入 /etc/nftables.conf 并应用规则 (TCP/UDP) ..."

# 备份原配置（可选）
if [ -f /etc/nftables.conf ]; then
  sudo cp /etc/nftables.conf /etc/nftables.conf.bak_$(date +%Y%m%d%H%M%S)
fi

# 将你的转发规则写入 /etc/nftables.conf
cat <<EOF | sudo tee /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

# 创建一个名为 forward_port 的表
table ip forward_port {

    # 1) 在 prerouting 链中使用 DNAT
    chain prerouting {
        type nat hook prerouting priority -100;
        # 转发 TCP 流量
        tcp dport $LOCAL_PORT dnat to $TARGET_IP:$TARGET_PORT
        # 转发 UDP 流量
        udp dport $LOCAL_PORT dnat to $TARGET_IP:$TARGET_PORT
    }

    # 2) 在 postrouting 链中使用 Masquerade
    chain postrouting {
        type nat hook postrouting priority 100;
        # 将目的地址是目标IP的包进行源地址伪装
        ip daddr $TARGET_IP masquerade
    }
}
EOF

# 加载新规则
sudo nft -f /etc/nftables.conf

echo
echo "[6/6] 检测是否有 UFW，并尝试放行本机端口 ${LOCAL_PORT} ..."
if command -v ufw >/dev/null 2>&1; then
  echo "  UFW 已安装，放行入站端口..."
  sudo ufw allow $LOCAL_PORT/tcp
  sudo ufw allow $LOCAL_PORT/udp
  echo "  完成放行。"
else
  echo "  UFW 未检测到或未安装，无需处理。"
fi

echo
echo "===================================================================="
echo "  [完成] nftables 端口转发配置成功！"
echo "  已将本机 :$LOCAL_PORT -> $TARGET_IP:$TARGET_PORT (TCP/UDP)"
echo
echo "  重启后依然有效，可执行以下命令查看规则："
echo "    sudo nft list ruleset"
echo
echo "===================================================================="
