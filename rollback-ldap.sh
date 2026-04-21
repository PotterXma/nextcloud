#!/usr/bin/env bash
# ============================================================
# Nextcloud LDAP 回滚脚本
# 用法: bash rollback-ldap.sh [config_id]
#   不带参数  → 列出所有配置并询问
#   带 s01    → 直接删 s01
# ============================================================
set -euo pipefail

CONTAINER="nextcloud_app"
OCC="docker exec -u www-data ${CONTAINER} php occ"

if [[ $# -ge 1 ]]; then
  CID="$1"
else
  echo "现有 LDAP 配置:"
  $OCC ldap:show-config
  read -rp "要删除哪个配置 ID? (例如 s01): " CID
fi

echo "==> 先失活"
$OCC ldap:set-config "$CID" ldapConfigurationActive "0"

echo "==> 删除配置"
$OCC ldap:delete-config "$CID"

echo "==> (可选) 禁用 user_ldap 应用"
read -rp "同时禁用 user_ldap 应用? [y/N]: " ans
if [[ "${ans,,}" == "y" ]]; then
  $OCC app:disable user_ldap
fi

echo
echo "⚠️  注意：LDAP 后端创建的用户记录不会自动删除。"
echo "   他们的 backend 现在会变成 'missing'，共享/文件仍存在数据库里。"
echo "   如果要彻底清理：$OCC user:delete <username>"
