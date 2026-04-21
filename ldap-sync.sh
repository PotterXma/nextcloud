#!/usr/bin/env bash
# ============================================================
# Nextcloud LDAP 定时同步脚本（供宿主机 cron 调用）
#
# 两种模式：
#   bash ldap-sync.sh           # 增量：只拉新用户、更新属性
#   bash ldap-sync.sh full      # 全量：自动 disable 离职账号 + 邮件通知
#
# 宿主机 crontab：
#   0 * * * *   /bin/bash /opt/nextcloud/ldap-sync.sh        >> /var/log/nc-ldap.log 2>&1
#   0 2 * * *   /bin/bash /opt/nextcloud/ldap-sync.sh full   >> /var/log/nc-ldap.log 2>&1
#
# 日志：/var/log/nc-ldap.log
# ============================================================
set -euo pipefail

# ---- 配置 ----
CONTAINER="nextcloud_app"
OCC="docker exec -u www-data ${CONTAINER} php occ"
MODE="${1:-incremental}"

SMTP_HOST="10.1.37.41"
SMTP_PORT="25"
MAIL_FROM="nextcloud@newegg.com"
MAIL_TO="ITInfrastructureTeam@newegg.com"   # admin 组邮箱
HOSTNAME_TAG="e11ncloud01"

# 临时文件（用于 diff）
SNAP_DIR="/tmp/nc-ldap-sync"
mkdir -p "${SNAP_DIR}"
BEFORE_FILE="${SNAP_DIR}/enabled_before.txt"
AFTER_FILE="${SNAP_DIR}/enabled_after.txt"
DIFF_FILE="${SNAP_DIR}/newly_disabled.txt"

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
    echo "From: Nextcloud Sync <${MAIL_FROM}>"
    echo "To: ${MAIL_TO}"
    echo "Subject: ${subject}"
    echo "Date: ${date_header}"
    echo "Content-Type: text/plain; charset=UTF-8"
    echo ""
    echo "${body}"
    echo "."
    sleep 1; echo "QUIT"
  } | nc -w 10 "${SMTP_HOST}" "${SMTP_PORT}" >/dev/null 2>&1 || {
    echo "[$(TS)] ⚠️  邮件发送失败（${SMTP_HOST}:${SMTP_PORT}）"
  }
}

# ---- 获取当前启用的用户列表 ----
get_enabled_users() {
  # 输出格式：每行一个 uid
  $OCC user:list --info 2>/dev/null \
    | grep -B1 'enabled: true' \
    | grep '^\s*-' \
    | sed 's/^[[:space:]]*- //' \
    | sed 's/:$//' \
    | sort
}

echo "========== [$(TS)] ldap-sync.sh start (mode=${MODE}) =========="

# ---- 前置检查 ----
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "[$(TS)] ❌ 容器 ${CONTAINER} 没在跑，退出"
  exit 1
fi

# ---- 核心同步 ----
case "${MODE}" in
  full|all|re-sync)
    # ===== 同步前快照 =====
    echo "[$(TS)] → 快照：记录当前启用的用户列表"
    get_enabled_users > "${BEFORE_FILE}"
    BEFORE_COUNT=$(wc -l < "${BEFORE_FILE}")
    echo "[$(TS)]   同步前启用用户: ${BEFORE_COUNT}"

    # ===== 执行全量同步 =====
    echo "[$(TS)] → 全量同步：user:sync user_ldap --re-sync-all --missing-account-action=disable"
    $OCC user:sync user_ldap --re-sync-all --missing-account-action=disable 2>&1 || true

    # ===== 同步后快照 =====
    echo "[$(TS)] → 快照：记录同步后启用的用户列表"
    get_enabled_users > "${AFTER_FILE}"
    AFTER_COUNT=$(wc -l < "${AFTER_FILE}")
    echo "[$(TS)]   同步后启用用户: ${AFTER_COUNT}"

    # ===== Diff：找出新被禁用的用户 =====
    # before 有但 after 没有 = 被 disable 了
    comm -23 "${BEFORE_FILE}" "${AFTER_FILE}" > "${DIFF_FILE}" || true
    NEW_DISABLED_COUNT=$(wc -l < "${DIFF_FILE}")

    echo "[$(TS)]   本次新禁用: ${NEW_DISABLED_COUNT}"

    # ===== 统计 =====
    USERS=$($OCC user:list | wc -l)
    GROUPS=$($OCC group:list | wc -l)
    TOTAL_DISABLED=$($OCC user:list --info 2>/dev/null | grep -c 'enabled: false' || echo 0)

    echo "[$(TS)] ✅ 同步完成. users=${USERS}  groups=${GROUPS}  disabled=${TOTAL_DISABLED}"

    # ===== 有新禁用用户 → 收集详情 + 邮件通知 =====
    if [[ ${NEW_DISABLED_COUNT} -gt 0 ]]; then
      echo "[$(TS)] 📋 检测到 ${NEW_DISABLED_COUNT} 个离职用户，收集详情..."

      DETAIL_LINES=""
      while IFS= read -r uid; do
        [[ -z "${uid}" ]] && continue

        # 收集数据大小
        DATA_SIZE=$(docker exec ${CONTAINER} du -sh "/var/www/html/data/${uid}/files" 2>/dev/null | awk '{print $1}' || echo "N/A")

        # 收集显示名
        DISPLAY_NAME=$($OCC user:info "${uid}" --output=json 2>/dev/null | grep -o '"displayName":"[^"]*"' | cut -d'"' -f4 || echo "${uid}")

        DETAIL_LINES="${DETAIL_LINES}
  用户: ${uid}
  显示名: ${DISPLAY_NAME}
  数据大小: ${DATA_SIZE}
  状态: 已自动禁用（AD 端已禁用/删除）
  ────────────────────────"
        echo "[$(TS)]   → ${uid} (${DISPLAY_NAME}, ${DATA_SIZE})"
      done < "${DIFF_FILE}"

      SUBJECT="⚠️ [Nextcloud] ${NEW_DISABLED_COUNT} 个员工离职 - 账号已自动禁用 ($(date +%F))"
      BODY="Nextcloud LDAP 全量同步检测到离职用户
服务器: ${HOSTNAME_TAG}
时间: $(TS)

══════════════════════════════
检测到以下用户在 AD 中已被禁用/删除
Nextcloud 已自动禁用其账号（数据保留）
══════════════════════════════
${DETAIL_LINES}

──────────────────────────────
同步统计
──────────────────────────────
  总用户数:    ${USERS}
  总组数:      ${GROUPS}
  已禁用总数:  ${TOTAL_DISABLED}
  本次新禁用:  ${NEW_DISABLED_COUNT}

──────────────────────────────
后续操作建议
──────────────────────────────
以上账号已被自动禁用，用户无法再登录。
文件和共享数据保留，不会自动删除。

如需交接文件给继任者：
  bash /opt/nextcloud/offboard-user.sh <离职邮箱> <继任者邮箱>

数据保留期（30-90天）结束后彻底删除：
  docker exec -u www-data nextcloud_app php occ user:delete <uid>

此邮件由 ldap-sync.sh 自动发送，无需回复。
"
      send_mail "${SUBJECT}" "${BODY}"
      echo "[$(TS)] 📧 邮件已发送至 ${MAIL_TO}"

    else
      # 无新禁用，静默完成（不发邮件，减少噪音）
      echo "[$(TS)] ℹ️  无新增禁用用户，跳过邮件"
    fi
    ;;

  incremental|incr)
    echo "[$(TS)] → 增量同步：触发 cron.php 一轮"
    docker exec -u www-data ${CONTAINER} php -f cron.php
    USERS=$($OCC user:list | wc -l)
    GROUPS=$($OCC group:list | wc -l)
    echo "[$(TS)] ✅ 完成. users=${USERS}  groups=${GROUPS}"
    ;;

  *)
    echo "[$(TS)] ❌ 未知模式: ${MODE}  (可选: incremental | full)"
    exit 2
    ;;
esac

echo "========== [$(TS)] ldap-sync.sh end =========="
echo
