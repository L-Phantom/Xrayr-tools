#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="xrayr-optimize"
CONFIG_FILE="/etc/XrayR/config.yml"
LOG_DIR="/var/log/XrayR"
BACKUP_ROOT="/root/xrayr-optimize-backups"
DRY_RUN=0
NO_RESTART=0
TRUNCATE_LOGS=1
ROLLBACK_DIR=""
PROFILE="safe"
EGRESS_MBIT=""
NO_TC=0

usage() {
  cat <<'EOF'
Usage:
  bash xrayr-optimize.sh [options]

Options:
  --profile NAME         safe, balanced, or saturated. Default: safe
  --egress-mbit N        Optional egress shaping rate in Mbit/s, for example 930
  --no-tc                Do not apply runtime qdisc/txqueuelen tuning
  --dry-run              Print planned actions without changing files
  --no-restart           Do not restart XrayR/systemd services
  --no-truncate-logs     Do not truncate existing XrayR logs
  --rollback DIR         Restore files from a backup directory created by this script
  -h, --help             Show this help

What this script optimizes:
  - XrayR config: disable file logs and REALITY debug "Show"
  - systemd: raise NOFILE/NPROC/TasksMax for XrayR
  - sysctl: apply conservative network/file-descriptor tuning
  - saturated profile: apply runtime fq qdisc/txqueuelen tuning
  - optional shaping: limit egress to --egress-mbit with htb+fq
  - logrotate: rotate /var/log/XrayR/*.log at 50M, keep 3 compressed copies
  - journald: cap journal disk/memory usage without overwriting the main config
  - logs: safely truncate existing oversized XrayR *.log files by default

It does not change nodes, UUIDs, private keys, DNS, certificates, routing rules,
firewall rules, or kernel packages.
EOF
}

log() { printf '[%s] %s\n' "$SCRIPT_NAME" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[%s] DRY-RUN: %s\n' "$SCRIPT_NAME" "$*"
  else
    "$@"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --profile)
      shift
      [ "${1:-}" ] || die "--profile requires a value"
      PROFILE="$1"
      ;;
    --egress-mbit)
      shift
      [ "${1:-}" ] || die "--egress-mbit requires a value"
      EGRESS_MBIT="$1"
      ;;
    --no-tc) NO_TC=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-restart) NO_RESTART=1 ;;
    --no-truncate-logs) TRUNCATE_LOGS=0 ;;
    --rollback)
      shift
      [ "${1:-}" ] || die "--rollback requires a directory"
      ROLLBACK_DIR="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "run as root"

case "$PROFILE" in
  safe|balanced|saturated) ;;
  *) die "--profile must be safe, balanced, or saturated" ;;
esac

if [ "$EGRESS_MBIT" ]; then
  case "$EGRESS_MBIT" in
    *[!0-9]*|'') die "--egress-mbit must be a positive integer" ;;
  esac
  [ "$EGRESS_MBIT" -gt 0 ] || die "--egress-mbit must be greater than 0"
fi

detect_service() {
  if systemctl list-unit-files XrayR.service >/dev/null 2>&1; then
    printf 'XrayR.service'
  elif systemctl list-unit-files xrayr.service >/dev/null 2>&1; then
    printf 'xrayr.service'
  elif systemctl status XrayR >/dev/null 2>&1; then
    printf 'XrayR.service'
  elif systemctl status xrayr >/dev/null 2>&1; then
    printf 'xrayr.service'
  else
    printf 'XrayR.service'
  fi
}

SERVICE_UNIT="$(detect_service)"
DROPIN_DIR="/etc/systemd/system/${SERVICE_UNIT}.d"

make_backup_dir() {
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  BACKUP_DIR="${BACKUP_ROOT}/${stamp}"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: backup directory would be ${BACKUP_DIR}"
  else
    mkdir -p "${BACKUP_DIR}/files"
    : > "${BACKUP_DIR}/backed_files"
    : > "${BACKUP_DIR}/created_files"
    printf 'service_unit=%s\n' "$SERVICE_UNIT" > "${BACKUP_DIR}/meta"
    write_rollback_helper
  fi
}

write_rollback_helper() {
  cat > "${BACKUP_DIR}/rollback.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_UNIT="XrayR.service"
if [ -f "${DIR}/meta" ]; then
  # shellcheck disable=SC1090
  . "${DIR}/meta"
fi

log() { printf '[xrayr-optimize-rollback] %s\n' "$*"; }

if [ -f "${DIR}/backed_files" ]; then
  while IFS= read -r path; do
    [ "$path" ] || continue
    if [ -e "${DIR}/files${path}" ]; then
      log "restore ${path}"
      mkdir -p "$(dirname "$path")"
      cp -a "${DIR}/files${path}" "$path"
    fi
  done < "${DIR}/backed_files"
fi

if [ -f "${DIR}/created_files" ]; then
  while IFS= read -r path; do
    [ "$path" ] || continue
    log "remove created file ${path}"
    rm -f "$path"
  done < "${DIR}/created_files"
fi

systemctl daemon-reload || true
systemctl restart systemd-journald || true
systemctl disable --now xrayr-net-tune.service >/dev/null 2>&1 || true
systemctl restart "$SERVICE_UNIT" || true
log "rollback complete"
EOF
  chmod 0700 "${BACKUP_DIR}/rollback.sh"
}

backup_file() {
  local path="$1"
  [ "$DRY_RUN" -eq 1 ] && { log "DRY-RUN: backup ${path}"; return 0; }
  mkdir -p "${BACKUP_DIR}/files$(dirname "$path")"
  if [ -e "$path" ]; then
    cp -a "$path" "${BACKUP_DIR}/files${path}"
    printf '%s\n' "$path" >> "${BACKUP_DIR}/backed_files"
  else
    printf '%s\n' "$path" >> "${BACKUP_DIR}/created_files"
  fi
}

write_file() {
  local path="$1"
  local content="$2"
  backup_file "$path"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: write ${path}"
  else
    mkdir -p "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
  fi
}

rollback() {
  local dir="$1"
  [ -d "$dir" ] || die "rollback directory not found: $dir"
  [ "$DRY_RUN" -eq 1 ] && log "DRY-RUN: rollback from $dir"

  if [ -f "${dir}/backed_files" ]; then
    while IFS= read -r path; do
      [ "$path" ] || continue
      if [ -e "${dir}/files${path}" ]; then
        log "restore ${path}"
        if [ "$DRY_RUN" -eq 0 ]; then
          mkdir -p "$(dirname "$path")"
          cp -a "${dir}/files${path}" "$path"
        fi
      fi
    done < "${dir}/backed_files"
  fi

  if [ -f "${dir}/created_files" ]; then
    while IFS= read -r path; do
      [ "$path" ] || continue
      log "remove created file ${path}"
      [ "$DRY_RUN" -eq 0 ] && rm -f "$path"
    done < "${dir}/created_files"
  fi

  if [ "$NO_RESTART" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    systemctl daemon-reload || true
    systemctl restart systemd-journald || true
    systemctl disable --now xrayr-net-tune.service >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_UNIT" || true
  fi
  log "rollback complete"
}

if [ "$ROLLBACK_DIR" ]; then
  rollback "$ROLLBACK_DIR"
  exit 0
fi

make_backup_dir
log "service unit: ${SERVICE_UNIT}"
log "backup directory: ${BACKUP_DIR:-dry-run}"

optimize_xrayr_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    log "skip XrayR config: ${CONFIG_FILE} not found"
    return 0
  fi

  backup_file "$CONFIG_FILE"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: disable XrayR logs and REALITY debug in ${CONFIG_FILE}"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CONFIG_FILE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines(True)
out = []
for line in lines:
    if re.match(r'^\s*Level\s*:', line):
        indent = re.match(r'^(\s*)', line).group(1)
        out.append(f'{indent}Level: none\n')
        continue
    if re.match(r'^\s*AccessPath\s*:', line):
        indent = re.match(r'^(\s*)', line).group(1)
        out.append(f'{indent}AccessPath: #\n')
        continue
    if re.match(r'^\s*ErrorPath\s*:', line):
        indent = re.match(r'^(\s*)', line).group(1)
        out.append(f'{indent}ErrorPath: #\n')
        continue
    if re.match(r'^\s*Show\s*:\s*true\b', line):
        indent = re.match(r'^(\s*)', line).group(1)
        comment = ''
        if '#' in line:
            comment = ' ' + line.split('#', 1)[1].rstrip('\n')
            comment = ' #' + comment.lstrip()
        out.append(f'{indent}Show: false{comment}\n')
        continue
    out.append(line)
path.write_text(''.join(out))
PY
  else
    sed -i -E \
      -e 's/^([[:space:]]*)Level[[:space:]]*:.*/\1Level: none/g' \
      -e 's/^([[:space:]]*)AccessPath[[:space:]]*:.*/\1AccessPath: #/g' \
      -e 's/^([[:space:]]*)ErrorPath[[:space:]]*:.*/\1ErrorPath: #/g' \
      -e 's/^([[:space:]]*)Show[[:space:]]*:[[:space:]]*true([[:space:]]*(#.*)?)$/\1Show: false\2/g' \
      "$CONFIG_FILE"
  fi
}

install_systemd_dropin() {
  local content
  content='[Service]
LimitNOFILE=1048576
LimitNPROC=1048576
TasksMax=infinity
Restart=always
RestartSec=3'
  write_file "${DROPIN_DIR}/10-performance.conf" "$content"
}

install_logrotate() {
  local content
  content='/var/log/XrayR/*.log {
    size 50M
    rotate 3
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0600 root root
}'
  write_file "/etc/logrotate.d/xrayr" "$content"
}

install_journald_limits() {
  local content
  content='[Journal]
SystemMaxUse=64M
RuntimeMaxUse=32M
MaxRetentionSec=2day
Compress=yes
ForwardToSyslog=no
ForwardToWall=no'
  write_file "/etc/systemd/journald.conf.d/99-xrayr-optimize.conf" "$content"
}

install_sysctl() {
  local cc extra="" backlog syn_backlog somax local_range fin_timeout keepalive_time rmem_max wmem_max netdev_budget=""
  cc="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if printf '%s' "$cc" | grep -qw bbr; then
    extra='
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr'
  else
    log "BBR not available; leaving congestion control unchanged"
  fi

  case "$PROFILE" in
    safe)
      backlog=250000
      syn_backlog=65535
      somax=65535
      local_range="10000 65000"
      fin_timeout=15
      keepalive_time=600
      rmem_max=67108864
      wmem_max=67108864
      ;;
    balanced)
      backlog=250000
      syn_backlog=131072
      somax=65535
      local_range="10000 65000"
      fin_timeout=12
      keepalive_time=480
      rmem_max=134217728
      wmem_max=134217728
      netdev_budget='
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000'
      ;;
    saturated)
      backlog=500000
      syn_backlog=262144
      somax=131072
      local_range="10000 65535"
      fin_timeout=10
      keepalive_time=300
      rmem_max=134217728
      wmem_max=134217728
      netdev_budget='
net.core.netdev_budget = 1200
net.core.netdev_budget_usecs = 10000'
      ;;
  esac

  local content
  content="# Managed by xrayr-optimize
fs.file-max = 1048576
net.core.somaxconn = ${somax}
net.core.netdev_max_backlog = ${backlog}
net.ipv4.ip_local_port_range = ${local_range}
net.ipv4.tcp_max_syn_backlog = ${syn_backlog}
net.ipv4.tcp_fin_timeout = ${fin_timeout}
net.ipv4.tcp_keepalive_time = ${keepalive_time}
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}
net.ipv4.tcp_wmem = 4096 65536 ${wmem_max}
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}${netdev_budget}${extra}"
  write_file "/etc/sysctl.d/99-xrayr-performance.conf" "$content"
}

detect_default_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

install_tc_service() {
  [ "$NO_TC" -eq 0 ] || { log "skip tc tuning due to --no-tc"; return 0; }
  local iface ip_bin tc_bin
  iface="$(detect_default_iface || true)"
  [ "$iface" ] || { log "skip tc tuning: cannot detect default interface"; return 0; }
  ip_bin="$(command -v ip || true)"
  tc_bin="$(command -v tc || true)"
  [ "$ip_bin" ] || { log "skip tc tuning: ip command not found"; return 0; }
  [ "$tc_bin" ] || { log "skip tc tuning: tc command not found"; return 0; }

  local cmd txqlen service_content
  case "$PROFILE" in
    safe) txqlen=1000 ;;
    balanced) txqlen=5000 ;;
    saturated) txqlen=10000 ;;
  esac

  if [ "$EGRESS_MBIT" ]; then
    cmd="${ip_bin} link set dev ${iface} txqueuelen ${txqlen}; ${tc_bin} qdisc replace dev ${iface} root handle 1: htb default 10; ${tc_bin} class replace dev ${iface} parent 1: classid 1:10 htb rate ${EGRESS_MBIT}mbit ceil ${EGRESS_MBIT}mbit; ${tc_bin} qdisc replace dev ${iface} parent 1:10 handle 10: fq"
  elif [ "$PROFILE" = "safe" ]; then
    cmd="${ip_bin} link set dev ${iface} txqueuelen ${txqlen}; ${tc_bin} qdisc replace dev ${iface} root fq || true"
  else
    cmd="${ip_bin} link set dev ${iface} txqueuelen ${txqlen}; ${tc_bin} qdisc replace dev ${iface} root fq || true"
  fi

  service_content="[Unit]
Description=XrayR network queue tuning
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c '${cmd}'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target"
  write_file "/etc/systemd/system/xrayr-net-tune.service" "$service_content"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would apply tc tuning on ${iface}"
    return 0
  fi

  systemctl daemon-reload || true
  systemctl enable xrayr-net-tune.service >/dev/null 2>&1 || true
  systemctl restart xrayr-net-tune.service || true
}

truncate_xrayr_logs() {
  [ "$TRUNCATE_LOGS" -eq 1 ] || { log "skip log truncation"; return 0; }
  [ -d "$LOG_DIR" ] || { log "skip log truncation: ${LOG_DIR} not found"; return 0; }

  local f size threshold
  threshold=$((50 * 1024 * 1024))
  for f in "$LOG_DIR"/*.log; do
    [ -f "$f" ] || continue
    size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    if [ "$size" -ge "$threshold" ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: truncate oversized log ${f} (${size} bytes)"
      else
        log "truncate oversized log ${f} (${size} bytes)"
        : > "$f"
      fi
    fi
  done
}

apply_changes() {
  optimize_xrayr_config
  install_systemd_dropin
  install_logrotate
  install_journald_limits
  install_sysctl
  install_tc_service
  truncate_xrayr_logs

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: would run systemctl daemon-reload, sysctl --system, restart journald/XrayR"
    return 0
  fi

  systemctl daemon-reload || true
  sysctl --system >/dev/null || true
  journalctl --vacuum-size=64M >/dev/null 2>&1 || true

  if [ "$NO_RESTART" -eq 0 ]; then
    systemctl restart systemd-journald || true
    systemctl restart "$SERVICE_UNIT"
  else
    log "skip service restart due to --no-restart"
  fi
}

apply_changes

log "done"
if [ "$DRY_RUN" -eq 0 ]; then
  systemctl is-active "$SERVICE_UNIT" >/dev/null 2>&1 && log "${SERVICE_UNIT} active" || log "${SERVICE_UNIT} not active; check: systemctl status ${SERVICE_UNIT}"
  df -h / | awk 'NR==1 || NR==2 {print}'
  log "rollback command: bash ${BACKUP_DIR}/rollback.sh"
fi
