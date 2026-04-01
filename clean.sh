#!/bin/bash

# 检查权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 权限运行此脚本。"
   exit 1
fi

# 1. 处理 XrayR 日志 (增强型匹配)
XRAYR_CONFIG="/etc/XrayR/config.yml"
if [ -f "$XRAYR_CONFIG" ]; then
    echo "正在处理 XrayR 配置文件..."
    # 备份一下以防万一
    cp "$XRAYR_CONFIG" "${XRAYR_CONFIG}.bak"
    
    # 更加精准的匹配：忽略大小写，处理可能存在的空格
    # 匹配包含 LogLevel 的行，并整行替换为 LogLevel: none
    sed -i -E 's/^[[:space:]]*LogLevel:.*/  LogLevel: none/I' "$XRAYR_CONFIG"
    
    # 检查是否修改成功
    if grep -iq "LogLevel: none" "$XRAYR_CONFIG"; then
        echo "✅ XrayR 配置修改成功：LogLevel 已设为 none"
    else
        echo "❌ 修改失败，请检查 config.yml 内部格式。"
    fi
    
    systemctl restart XrayR
else
    echo "⚠️ 未发现 XrayR 配置文件，请检查路径是否为 /etc/XrayR/config.yml"
fi

# 2. 处理 systemd-journald (这一步通常不会失败)
JOURNAL_CONF="/etc/systemd/journald.conf"
if [ -f "$JOURNAL_CONF" ]; then
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
    echo "✅ systemd-journald 优化完成。"
else
    echo "⚠️ 未找到 journald.conf"
fi
