#!/usr/bin/env bash
# ============================================================
# Nextcloud LDAP 定时同步 + 离职用户自动检测脚本
#
# 两种模式：
#   bash ldap-sync.sh           # 增量：触发 cron.php 跑 LDAP 后台同步
#   bash ldap-sync.sh full      # 全量：触发同步 + 检测离职用户 + 自动 disable + 邮件通知
#
# 工作原理（NC 33）：
#   Nextcloud 的 user_ldap 后台任务会自动检查 LDAP 用户是否还在 AD 中，
#   不在的会被标记为 remnants（ldap:show-remnants 可查）。
#   本脚本在 full 模式下额外做：
#     1. 触发一轮 cron.php（加速 LDAP 后台检测）
#     2. ldap:show-remnants --json 获取已标记的离职用户
#     3. 对每个 remnant 执行 user:disable（保留数据，禁止登录）
#     4. 邮件通知 admin 组
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

# 记录已处理过的 remnant，避免重复邮件
PROCESSED_FILE="/opt/nextcloud/.processed_remnants"
touch "${PROCESSED_FILE}" 2>/dev/null || true

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

echo "========== [$(TS)] ldap-sync.sh start (mode=${MODE}) =========="

# ---- 前置检查 ----
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "[$(TS)] ❌ 容器 ${CONTAINER} 没在跑，退出"
  exit 1
fi

# ---- 核心同步 ----
case "${MODE}" in
  full|all)
    # ===== 1. 触发一轮 cron.php，加速 LDAP 后台检测 =====
    echo "[$(TS)] → 触发 cron.php（加速 LDAP 用户检测）"
    docker exec -u www-data ${CONTAINER} php -f cron.php 2>&1 || true

    # ===== 2. 获取 remnants（AD 中已不存在的用户） =====
    echo "[$(TS)] → 检查 ldap:show-remnants"
    REMNANTS_JSON=$($OCC ldap:show-remnants --json 2>/dev/null || echo "[]")

    # 解析 JSON（用 python 处理，容器里自带）
    REMNANT_COUNT=$(echo "${REMNANTS_JSON}" | docker exec -i ${CONTAINER} \
      python3 -c "import sys,json; data=json.load(sys.stdin); print(len(data))" 2>/dev/null || echo "0")

    echo "[$(TS)]   remnants 总数: ${REMNANT_COUNT}"

    if [[ "${REMNANT_COUNT}" -gt 0 && "${REMNANT_COUNT}" != "0" ]]; then
      # 提取每个 remnant 的信息
      REMNANT_DETAILS=$(echo "${REMNANTS_JSON}" | docker exec -i ${CONTAINER} \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for u in data:
    nc_name = u.get('Nextcloud name', u.get('ocName', ''))
    display = u.get('Display Name', u.get('displayName', ''))
    dn = u.get('LDAP DN', u.get('dn', ''))
    detected = u.get('Detected on', u.get('detectTimestamp', ''))
    print(f'{nc_name}||{display}||{dn}||{detected}')
" 2>/dev/null || echo "")

      # 筛选未处理过的 remnant
      NEW_REMNANTS=""
      NEW_COUNT=0
      DETAIL_LINES=""

      while IFS='||' read -r nc_name display dn detected; do
        [[ -z "${nc_name}" ]] && continue

        # 检查是否已处理
        if grep -qF "${nc_name}" "${PROCESSED_FILE}" 2>/dev/null; then
          echo "[$(TS)]   ⏭️  ${nc_name} 已处理过，跳过"
          continue
        fi

        NEW_COUNT=$((NEW_COUNT + 1))

        # 禁用账号
        echo "[$(TS)]   → 禁用: ${nc_name} (${display})"
        $OCC user:disable "${nc_name}" 2>/dev/null || true

        # 获取数据大小
        DATA_SIZE=$(docker exec ${CONTAINER} du -sh "/var/www/html/data/${nc_name}/files" 2>/dev/null | awk '{print $1}' || echo "N/A")

        DETAIL_LINES="${DETAIL_LINES}
  用户: ${nc_name}
  显示名: ${display}
  LDAP DN: ${dn}
  检测时间: ${detected}
  数据大小: ${DATA_SIZE}
  处理: ✅ 已自动禁用
  ────────────────────────"

        # 记录为已处理
        echo "${nc_name}" >> "${PROCESSED_FILE}"

      done <<< "${REMNANT_DETAILS}"

      # 有新增离职用户才发邮件
      if [[ ${NEW_COUNT} -gt 0 ]]; then
        USERS=$($OCC user:list | wc -l)
        GROUPS=$($OCC group:list | wc -l)
        TOTAL_DISABLED=$($OCC user:list --info 2>/dev/null | grep -c 'enabled: false' || echo 0)

        SUBJECT="⚠️ [Nextcloud] ${NEW_COUNT} 个员工离职 - 账号已自动禁用 ($(date +%F))"
        BODY="Nextcloud LDAP 同步检测到离职用户
服务器: ${HOSTNAME_TAG}
时间: $(TS)

══════════════════════════════
以下用户在 AD 中已不存在
Nextcloud 已自动禁用其账号（数据保留）
══════════════════════════════
${DETAIL_LINES}

──────────────────────────────
当前统计
──────────────────────────────
  总用户数:    ${USERS}
  总组数:      ${GROUPS}
  已禁用总数:  ${TOTAL_DISABLED}
  本次新处理:  ${NEW_COUNT}

──────────────────────────────
后续操作
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
        echo "[$(TS)] 📧 邮件已发送至 ${MAIL_TO}（${NEW_COUNT} 个新离职用户）"
      else
        echo "[$(TS)] ℹ️  所有 remnants 已处理过，无新增"
      fi
    else
      echo "[$(TS)] ✅ 无离职用户（remnants=0）"
    fi

    # ===== 3. 统计 =====
    USERS=$($OCC user:list | wc -l)
    GROUPS=$($OCC group:list | wc -l)
    echo "[$(TS)] ✅ 同步完成. users=${USERS}  groups=${GROUPS}"
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
