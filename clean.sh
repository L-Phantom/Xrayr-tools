#!/bin/bash

# 检查权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 处理 XrayR 日志
XRAYR_CONFIG="/etc/XrayR/config.yml"
if [ -f "$XRAYR_CONFIG" ]; then
    sed -i 's/LogLevel:.*/LogLevel: none/g' "$XRAYR_CONFIG"
    systemctl restart XrayR
    echo "XrayR 日志已关闭并重启服务。"
else
    echo "未发现 XrayR 配置文件。"
fi

# 2. 处理 systemd-journald
JOURNAL_CONF="/etc/systemd/journald.conf"
cp $JOURNAL_CONF "${JOURNAL_CONF}.bak"
cat > $JOURNAL_CONF <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=30M
MaxRetentionSec=1day
ForwardToSyslog=no
ForwardToWall=no
EOF

systemctl restart systemd-journald
echo "systemd-journald 已限制在内存中运行。"
