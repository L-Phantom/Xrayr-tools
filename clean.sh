#!/bin/bash

# 1. 精准处理 XrayR 的 Level 缩进
XRAYR_CONFIG="/etc/XrayR/config.yml"

if [ -f "$XRAYR_CONFIG" ]; then
    echo "正在修复空格缩进并关闭日志..."
    cp "$XRAYR_CONFIG" "${XRAYR_CONFIG}.bak"

    # 这里的正则含义：匹配行首开始的任意空格，紧跟 Level:，然后把整行换掉
    # 我们尝试用最标准的 2 空格缩进，如果你的环境特殊，这一行也能强行纠正它
    sed -i -E 's/^[[:space:]]*Level:.*/  Level: none/g' "$XRAYR_CONFIG"
    
    # 同时也把 AccessPath 和 ErrorPath 的注释前面对齐
    sed -i -E 's/^[[:space:]]*AccessPath:.*/  AccessPath: #/g' "$XRAYR_CONFIG"
    sed -i -E 's/^[[:space:]]*ErrorPath:.*/  ErrorPath: #/g' "$XRAYR_CONFIG"

    echo "✅ 缩进已修正，Level 已设为 none。"
    systemctl restart XrayR
else
    echo "❌ 找不到文件！"
fi

# 2. 系统日志限流 (这个部分不需要改，保持强力压缩)
JOURNAL_CONF="/etc/systemd/journald.conf"
if [ -f "$JOURNAL_CONF" ]; then
    cat > $JOURNAL_CONF <<EOF
[Journal]
Storage=volatile
RuntimeMaxUse=10M
MaxRetentionSec=1h
ForwardToSyslog=no
ForwardToWall=no
EOF
    journalctl --vacuum-time=1s
    systemctl restart systemd-journald
    echo "✅ systemd-journald 限制已生效。"
fi
