#!/usr/bin/env bash
# ============================================================
# Nextcloud 定时任务一键部署脚本
# 在服务器上执行：bash setup-cron.sh
#
# 功能：
#   1. 拷贝运维脚本到 /opt/nextcloud/
#   2. 创建日志文件
#   3. 注册宿主机 crontab
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="/opt/nextcloud"
LOG_FILE="/var/log/nc-ldap.log"

echo "========================================"
echo " Nextcloud 定时任务部署"
echo "========================================"

# ---- 1. 创建目标目录 ----
echo "→ 创建 ${DEPLOY_DIR}"
mkdir -p "${DEPLOY_DIR}"

# ---- 2. 拷贝脚本 ----
echo "→ 部署脚本到 ${DEPLOY_DIR}"
cp -v "${SCRIPT_DIR}/ldap-sync.sh"    "${DEPLOY_DIR}/ldap-sync.sh"
cp -v "${SCRIPT_DIR}/offboard-user.sh" "${DEPLOY_DIR}/offboard-user.sh"
chmod +x "${DEPLOY_DIR}/ldap-sync.sh"
chmod +x "${DEPLOY_DIR}/offboard-user.sh"

# ---- 3. 创建日志文件 ----
echo "→ 创建日志 ${LOG_FILE}"
touch "${LOG_FILE}"

# ---- 4. 注册 crontab（幂等：先删旧的再加新的）----
echo "→ 注册 crontab"

# 标记行，用于识别我们的 cron 条目
CRON_MARKER="# nextcloud-ldap-sync"

# 导出当前 crontab（忽略 "no crontab" 错误）
CURRENT_CRON=$(crontab -l 2>/dev/null || true)

# 移除旧条目
CLEANED_CRON=$(echo "${CURRENT_CRON}" | grep -v "${CRON_MARKER}" | grep -v "ldap-sync.sh" || true)

# 追加新条目
NEW_CRON="${CLEANED_CRON}
${CRON_MARKER}
# LDAP 增量同步 - 每小时
0 * * * *   /bin/bash ${DEPLOY_DIR}/ldap-sync.sh        >> ${LOG_FILE} 2>&1 ${CRON_MARKER}
# LDAP 全量同步 - 每天凌晨 2 点（自动检测离职 + 邮件通知）
0 2 * * *   /bin/bash ${DEPLOY_DIR}/ldap-sync.sh full   >> ${LOG_FILE} 2>&1 ${CRON_MARKER}
"

# 写入
echo "${NEW_CRON}" | crontab -

echo
echo "========================================"
echo " ✅ 部署完成"
echo "========================================"
echo
echo " 脚本位置:  ${DEPLOY_DIR}/"
echo " 日志位置:  ${LOG_FILE}"
echo
echo " 当前 crontab:"
crontab -l | grep -A1 "${CRON_MARKER}" || true
echo
echo " 手动测试:"
echo "   bash ${DEPLOY_DIR}/ldap-sync.sh          # 增量"
echo "   bash ${DEPLOY_DIR}/ldap-sync.sh full     # 全量（会发邮件）"
echo
