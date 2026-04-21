#!/usr/bin/env bash
# ============================================================
# Nextcloud LDAP 定时同步脚本（供宿主机 cron 调用）
#
# 两种模式：
#   bash ldap-sync.sh           # 增量：只拉新用户、更新已有账号属性
#   bash ldap-sync.sh full      # 全量：--re-sync-all，自动 disable 离职账号，邮件通知 admin
#
# 宿主机 crontab 配置（部署后执行 crontab -e 添加）：
#   # 每小时增量
#   0 * * * *   /bin/bash /opt/nextcloud/ldap-sync.sh        >> /var/log/nc-ldap.log 2>&1
#   # 每天凌晨 2 点全量（会自动 disable 已离职账号 + 邮件通知）
#   0 2 * * *   /bin/bash /opt/nextcloud/ldap-sync.sh full   >> /var/log/nc-ldap.log 2>&1
#
# 日志：/var/log/nc-ldap.log
# ============================================================
set -euo pipefail

# ---- 配置 ----
CONTAINER="nextcloud_app"
OCC="docker exec -u www-data ${CONTAINER} php occ"
MODE="${1:-incremental}"

# 邮件配置
SMTP_HOST="10.1.37.41"
SMTP_PORT="25"
MAIL_FROM="nextcloud@newegg.com"
MAIL_TO="ITInfrastructureTeam@newegg.com"   # admin 组邮箱，按需修改
MAIL_DOMAIN="newegg.com"
HOSTNAME_TAG="e11ncloud01"

TS() { date '+%F %T'; }

# ---- 发送邮件（raw SMTP，不依赖任何邮件包） ----
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
    echo "[$(TS)] ⚠️  邮件发送失败（${SMTP_HOST}:${SMTP_PORT}），不影响同步"
  }
}

echo "========== [$(TS)] ldap-sync.sh start (mode=${MODE}) =========="

# ---- 前置检查 ----
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "[$(TS)] ❌ 容器 ${CONTAINER} 没在跑，退出"
  exit 1
fi

# ---- 同步前快照（用于 diff） ----
DISABLED_BEFORE=$($OCC user:list --info 2>/dev/null | grep -c 'enabled: false' || echo 0)

# ---- 核心同步 ----
case "${MODE}" in
  full|all|re-sync)
    echo "[$(TS)] → 全量同步：user:sync -u user_ldap --re-sync-all --missing-account-action=disable"
    SYNC_OUTPUT=$($OCC user:sync -u user_ldap --re-sync-all --missing-account-action=disable 2>&1) || true
    echo "${SYNC_OUTPUT}"
    ;;

  incremental|incr)
    echo "[$(TS)] → 增量同步：触发 cron.php 一轮"
    docker exec -u www-data ${CONTAINER} php -f cron.php
    ;;

  *)
    echo "[$(TS)] ❌ 未知模式: ${MODE}  (可选: incremental | full)"
    exit 2
    ;;
esac

# ---- 统计 ----
USERS=$($OCC user:list | wc -l)
GROUPS=$($OCC group:list | wc -l)
DISABLED_AFTER=$($OCC user:list --info 2>/dev/null | grep -c 'enabled: false' || echo 0)
NEW_DISABLED=$((DISABLED_AFTER - DISABLED_BEFORE))

echo "[$(TS)] ✅ 完成. users=${USERS}  groups=${GROUPS}  disabled=${DISABLED_AFTER} (新增: ${NEW_DISABLED})"

# ---- 全量同步后发邮件报告 ----
if [[ "${MODE}" == "full" || "${MODE}" == "all" || "${MODE}" == "re-sync" ]]; then
  # 列出所有被 disable 的用户
  DISABLED_LIST=$($OCC user:list --info 2>/dev/null | grep -B1 'enabled: false' | grep -v 'enabled:' | grep -v '^--$' | sed 's/^[[:space:]]*- //' || echo "(无)")

  SUBJECT="[Nextcloud] LDAP 全量同步报告 - $(date +%F)"
  BODY="Nextcloud LDAP 全量同步已完成
服务器: ${HOSTNAME_TAG}
时间: $(TS)

──────────────────────────────
统计
──────────────────────────────
  总用户数:    ${USERS}
  总组数:      ${GROUPS}
  已禁用账号:  ${DISABLED_AFTER}
  本次新禁用:  ${NEW_DISABLED}

──────────────────────────────
当前所有被禁用的账号
──────────────────────────────
${DISABLED_LIST}
"

  # 有新增禁用时，邮件标题更醒目
  if [[ ${NEW_DISABLED} -gt 0 ]]; then
    SUBJECT="⚠️ [Nextcloud] ${NEW_DISABLED} 个账号被自动禁用 - $(date +%F)"
    BODY="${BODY}
──────────────────────────────
⚠️ 注意
──────────────────────────────
以上 ${NEW_DISABLED} 个账号在 AD 中已被禁用/删除，
Nextcloud 端已自动 disable（数据保留，登录已拒）。

如需交接文件，请使用：
  bash /opt/nextcloud/offboard-user.sh <离职邮箱> <继任者邮箱>

如已过数据保留期（30-90天），可彻底删除：
  docker exec -u www-data nextcloud_app php occ user:delete <uid>
"
  fi

  send_mail "${SUBJECT}" "${BODY}"
  echo "[$(TS)] 📧 邮件已发送至 ${MAIL_TO}"
fi

echo "========== [$(TS)] ldap-sync.sh end =========="
echo
