#!/bin/bash

# 检查权限
if [[ $EUID -ne 0 ]]; then
   echo "请使用 root 权限运行此脚本。"
   exit 1
fi

XRAYR_CONFIG="/etc/XrayR/config.yml"

if [ -f "$XRAYR_CONFIG" ]; then
    echo "正在重新构建日志配置模块..."
    # 备份
    cp "$XRAYR_CONFIG" "${XRAYR_CONFIG}.bak"

    # 第一步：删除原文件中从 "Log:" 开始到 "ConnectionConfig:" 之前的所有内容
    # 第二步：在原来的位置插入我们标准的、关闭日志的配置
    # 这样管你原来是 Level 还是 LogLevel，全部推倒重来
    
    # 创建一个临时文件来重新组装配置
    sed -i '/^Log:/,/^ConnectionConfig:/c\Log:\n  Level: none\n  AccessPath: # /etc/XrayR/access.Log\n  ErrorPath: # /etc/XrayR/error.log\n\nDnsConfigPath: # /etc/XrayR/dns.json\n\nConnectionConfig:' "$XRAYR_CONFIG"

    echo "✅ XrayR 配置已重写，LogLevel 强制设为 none。"
    systemctl restart XrayR
else
    echo "⚠️ 找不到配置文件！"
fi

# 优化系统日志 (针对 systemd-journald)
echo "正在深度清理系统日志占用..."
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
    # 清理现有的 journal 日志
    journalctl --vacuum-time=1s
    systemctl restart systemd-journald
    echo "✅ 系统日志已锁定在内存 (10M上限) 并清空历史。"
fi

echo "--- 任务完成，L-Phantom 祝你节点稳如老狗 ---"
