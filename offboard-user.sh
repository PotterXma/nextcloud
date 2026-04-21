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

# 邮件配置
SMTP_HOST="10.1.37.41"
SMTP_PORT="25"
MAIL_FROM="nextcloud@newegg.com"
MAIL_TO="suntek.q.ma@newegg.com"   # admin 组邮箱，按需修改
HOSTNAME_TAG="e11ncloud01"

if [[ $# -lt 1 ]]; then
  echo "用法: bash $0 <离职员工UID> [<交接给的同事UID>]"
  exit 1
fi

LEAVER="$1"
SUCCESSOR="${2:-}"
TS() { date '+%F %T'; }

# ---- 发送邮件（raw SMTP） ----
send_mail() {
  local subject="$1"
  local body="$2"
  local date_header
  date_header=$(date -R 2>/dev/null || date '+%a, %d %b %Y %T %z')

  {
    sleep 1; echo "EHLO ${HOSTNAME_TAG}"
    sleep 1; echo "MAIL FROM:<${MAIL_FROM}>"
    sleep 1; echo "RCPT TO:<${MAIL_TO}>"
    sleep 1; echo "DATA"
    sleep 1
    echo "From: Nextcloud Admin <${MAIL_FROM}>"
    echo "To: ${MAIL_TO}"
    echo "Subject: ${subject}"
    echo "Date: ${date_header}"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo ""
    echo "${body}"
    echo "."
    sleep 1; echo "QUIT"
  } | nc -w 10 "${SMTP_HOST}" "${SMTP_PORT}" >/dev/null 2>&1 || {
    echo "[$(TS)] ⚠️  邮件发送失败（${SMTP_HOST}:${SMTP_PORT}），不影响离职处理"
  }
}

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

# 收集用户数据大小（用于邮件报告）
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

# ---- 4. 终止所有活跃会话 ----
echo
echo ">>> [3/3] 注销所有活跃会话"
$OCC user:disable "${LEAVER}" >/dev/null 2>&1 || true
echo "    ℹ️  账号 disable 后，新请求会被拒，已签发的 token 会在过期后失效"
echo "       如需立刻失效所有客户端，可选：$OCC user:resetpassword ${LEAVER}"

# ---- 5. 发送邮件通知 ----
SUBJECT="🚪 [Nextcloud] 员工离职处理完成 - ${LEAVER}"
BODY="Nextcloud 员工离职封存操作已完成
服务器: ${HOSTNAME_TAG}
操作时间: $(TS)
操作人: $(whoami)@$(hostname)

──────────────────────────────
离职员工信息
──────────────────────────────
  UID:        ${LEAVER}
  数据大小:   ${DATA_SIZE}
  账号状态:   已禁用 (disabled)

──────────────────────────────
文件交接
──────────────────────────────
  ${TRANSFER_STATUS}

──────────────────────────────
后续待办
──────────────────────────────
  1. 确认 AD 端已禁用该账号
  2. 审计：检查该用户的 public share 链接
  3. 数据保留期（30-90天）结束后彻底删除：
     docker exec -u www-data nextcloud_app php occ user:delete ${LEAVER}
     docker exec -u www-data nextcloud_app php occ ldap:reset-user ${LEAVER}
"

send_mail "${SUBJECT}" "${BODY}"
echo
echo "📧 邮件通知已发送至 ${MAIL_TO}"

# ---- 6. 输出后续步骤 ----
echo
echo "========================================================"
echo " ✅ 封存完成。后续建议："
echo "========================================================"
echo " 1. AD 端：请 HR/IT 同步禁用 AD 账号（我们的 LDAP 过滤器会排除禁用账号）"
echo " 2. 审计：导出该用户的最后活动日志"
echo "      $OCC log:tail 500 | grep -i ${LEAVER}"
echo " 3. 共享链接：检查并撤销该用户创建的 public share"
echo "      docker exec -u www-data ${CONTAINER} php occ files:scan --shallow --path=\"/${LEAVER}/files\""
echo " 4. 数据保留期（默认 30-90 天）结束后，彻底删除："
echo "      $OCC user:delete ${LEAVER}"
echo "      $OCC ldap:reset-user ${LEAVER}    # 如果 LDAP mapping 残留"
echo
