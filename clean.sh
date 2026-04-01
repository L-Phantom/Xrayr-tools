#!/bin/bash

# 检查权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 权限运行此脚本。"
   exit 1
fi

XRAYR_CONFIG="/etc/XrayR/config.yml"

# 1. 针对你的格式进行精准打击
if [ -f "$XRAYR_CONFIG" ]; then
    echo "检测到 XrayR 配置文件，正在执行精准修改..."
    cp "$XRAYR_CONFIG" "${XRAYR_CONFIG}.bak"

    # 逻辑：找到 Log: 下方的第一行 Level，并将其修改为 none
    # 匹配模式：匹配以任意空格开始的 Level: 后面跟着任何内容的行
    sed -i 's/^[[:space:]]*Level:.*/    Level: none/g' "$XRAYR_CONFIG"
    
    # 如果你的配置里连 Level 这行都没有，我们可以直接在 Log: 后面插入
    if ! grep -iq "Level: none" "$XRAYR_CONFIG"; then
        sed -i '/Log:/a \    Level: none' "$XRAYR_CONFIG"
    fi

    echo "✅ XrayR 日志级别已设为 none。"
    systemctl restart XrayR
else
    echo "⚠️ 路径不对，请确认配置文件在 /etc/XrayR/config.yml"
fi

# 2. 处理 systemd-journald (系统层级优化)
JOURNAL_CONF="/etc/systemd/journald.conf"
if [ -f "$JOURNAL_CONF" ]; then
    cat > $JOURNAL_CONF <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=20M
MaxRetentionSec=1day
ForwardToSyslog=no
ForwardToWall=no
EOF
    systemctl restart systemd-journald
    echo "✅ systemd-journald 已限制在内存运行 (20M上限)。"
else
    echo "⚠️ 未找到 journald.conf"
fi

echo "--- L-Phantom 优化脚本执行完毕 ---"
