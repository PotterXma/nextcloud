#!/usr/bin/env bash
# ============================================================
# Nextcloud 员工离职处理脚本
#
# 用法：
#   bash offboard-user.sh <离职员工邮箱>                       # 只 disable
#   bash offboard-user.sh <离职员工邮箱> <交接给的同事邮箱>      # disable + 文件交接
#
# 示例：
#   bash offboard-user.sh leaver@newegg.com
#   bash offboard-user.sh leaver@newegg.com manager@newegg.com
#
# 说明：
#   本脚本只做「封存」动作，不删号、不删数据。
#   正式删除（含数据）走 IT 流程 30-90 天保留期之后，手工执行：
#     $OCC user:delete <uid>
# ============================================================
set -euo pipefail

# ---- 配置 ----
CONTAINER="nextcloud_app"
OCC="docker exec -u www-data ${CONTAINER} php occ"

if [[ $# -lt 1 ]]; then
  echo "用法: bash $0 <离职员工UID> [<交接给的同事UID>]"
  exit 1
fi

LEAVER="$1"
SUCCESSOR="${2:-}"
TS() { date '+%F %T'; }

echo "========================================================"
echo " 离职处理: ${LEAVER}"
[[ -n "${SUCCESSOR}" ]] && echo " 文件交接给: ${SUCCESSOR}"
echo "========================================================"

# ---- 1. 核对用户存在 ----
if ! $OCC user:info "${LEAVER}" >/dev/null 2>&1; then
  echo "❌ 用户 ${LEAVER} 不存在，请确认 UID（一般是邮箱）"
  exit 2
fi

echo
echo ">>> 当前状态："
USER_INFO=$($OCC user:info "${LEAVER}" 2>&1)
echo "${USER_INFO}"

# 收集用户数据大小（控制台摘要）
DATA_SIZE=$(docker exec ${CONTAINER} du -sh "/var/www/html/data/${LEAVER}/files" 2>/dev/null | awk '{print $1}' || echo "未知")

TRANSFER_STATUS="未执行文件交接"

# ---- 2. 交接文件（可选，必须先做，disable 之后可能 transfer 不了）----
if [[ -n "${SUCCESSOR}" ]]; then
  if ! $OCC user:info "${SUCCESSOR}" >/dev/null 2>&1; then
    echo "❌ 继任者 ${SUCCESSOR} 不存在，停止"
    exit 3
  fi
  echo
  echo ">>> [1/3] 文件所有权交接: ${LEAVER} → ${SUCCESSOR}"
  read -rp "    确认执行 files:transfer-ownership 吗? [y/N]: " ans
  if [[ "${ans,,}" == "y" ]]; then
    $OCC files:transfer-ownership "${LEAVER}" "${SUCCESSOR}"
    TRANSFER_STATUS="✅ 已交接给 ${SUCCESSOR}"
    echo "    ✅ 交接完成"
  else
    TRANSFER_STATUS="⚠️ 操作员跳过了文件交接"
    echo "    ⚠️  跳过文件交接"
  fi
else
  echo
  echo ">>> [1/3] 没指定继任者，跳过文件交接"
fi

# ---- 3. 禁用账号 ----
echo
echo ">>> [2/3] 禁用 Nextcloud 账号"
$OCC user:disable "${LEAVER}"
echo "    ✅ 账号已 disable，登录将被拒"

# ---- 4. 会话说明 ----
echo
echo ">>> [3/3] 会话与令牌"
$OCC user:disable "${LEAVER}" >/dev/null 2>&1 || true
echo "    ℹ️  账号 disable 后，新请求会被拒，已签发的 token 会在过期后失效"
echo "       如需立刻失效所有客户端，可选：$OCC user:resetpassword ${LEAVER}"

echo
echo "──────────────────────────────"
echo " 摘要（$(TS)）"
echo "  UID: ${LEAVER}"
echo "  数据大小: ${DATA_SIZE}"
echo "  文件交接: ${TRANSFER_STATUS}"
echo "──────────────────────────────"

# ---- 5. 输出后续步骤 ----
echo
echo "========================================================"
echo " ✅ 封存完成。后续建议："
echo "========================================================"
echo " 1. 企业账号侧：请 HR/IT 按流程禁用该用户在公司统一身份 / 目录中的账号"
echo " 2. 审计：导出该用户的最后活动日志"
echo "      $OCC log:tail 500 | grep -i ${LEAVER}"
echo " 3. 共享链接：检查并撤销该用户创建的 public share"
echo "      docker exec -u www-data ${CONTAINER} php occ files:scan --shallow --path=\"/${LEAVER}/files\""
echo " 4. 数据保留期（默认 30-90 天）结束后，彻底删除："
echo "      $OCC user:delete ${LEAVER}"
echo
