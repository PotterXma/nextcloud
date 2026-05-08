#!/usr/bin/env bash
# ============================================================
# Nextcloud 运维脚本一键部署（宿主机 /opt/nextcloud）
# 在服务器上执行：bash setup-cron.sh
#
# 功能：
#   1. 拷贝 offboard-user.sh 等脚本到 /opt/nextcloud/
#   2. 从 crontab 移除旧版 ldap-sync.sh 相关条目（若曾部署过）
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPLOY_DIR="/opt/nextcloud"
CRON_MARKER="# nextcloud-ldap-sync"

echo "========================================"
echo " Nextcloud 运维脚本部署"
echo "========================================"

# ---- 1. 创建目标目录 ----
echo "→ 创建 ${DEPLOY_DIR}"
mkdir -p "${DEPLOY_DIR}"

# ---- 2. 拷贝脚本 ----
if [[ "$(realpath "${SCRIPT_DIR}")" == "$(realpath "${DEPLOY_DIR}")" ]]; then
  echo "→ 脚本已在 ${DEPLOY_DIR}，跳过拷贝"
else
  echo "→ 部署脚本到 ${DEPLOY_DIR}"
  cp -v "${SCRIPT_DIR}/offboard-user.sh" "${DEPLOY_DIR}/offboard-user.sh"
fi
chmod +x "${DEPLOY_DIR}/offboard-user.sh"

# ---- 3. 清理旧版同步 cron 条目（幂等）----
echo "→ 清理 crontab 中的旧版 ldap-sync 条目（如有）"
CURRENT_CRON=$(crontab -l 2>/dev/null || true)
CLEANED_CRON=$(echo "${CURRENT_CRON}" | grep -v "${CRON_MARKER}" | grep -v "ldap-sync.sh" || true)
echo "${CLEANED_CRON}" | crontab -

echo
echo "========================================"
echo " ✅ 部署完成"
echo "========================================"
echo
echo " 脚本位置:  ${DEPLOY_DIR}/offboard-user.sh"
echo " 离职处理:  bash ${DEPLOY_DIR}/offboard-user.sh <uid> [<继任者uid>]"
echo
