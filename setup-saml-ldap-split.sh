#!/usr/bin/env bash
# ============================================================
# 配置 SAML + LDAP 职责分离架构
#   - SAML  → 只负责认证 (AuthN)
#   - LDAP  → 负责用户目录 (mail/displayName/groups/sharing)
#
# 前置: user_saml 已配好(s01 是 SAML 的 idp ID, 一般是 1)
#       user_ldap 已配好(s01 是 LDAP 的 config ID)
# ============================================================
set -euo pipefail

CONTAINER="nextcloud_app"
OCC="docker exec -u www-data ${CONTAINER} php occ"

# 如果你的 SAML idp ID 不是 1，改这里（用 occ saml:config:list 查）
SAML_IDP_ID="1"

echo "==> 1. 检查 LDAP 后端工作正常"
$OCC ldap:test-config s01 || { echo "❌ LDAP 还没配好，先解决 LDAP 再来"; exit 1; }
$OCC user:search '' --limit 1 >/dev/null && echo "   ✅ LDAP 能搜到用户"

echo
echo "==> 2. 列出当前 SAML 配置（备份原值）"
$OCC saml:config:get "$SAML_IDP_ID" > /tmp/saml-backup-$(date +%s).txt
echo "   已备份到 /tmp/saml-backup-*.txt"

echo
echo "==> 3. 关键开关：允许多后端 + 禁止 SAML 自建用户"
# 允许 SAML 和 LDAP 共存
$OCC config:app:set user_saml type --value="environment-variable"  2>/dev/null || true

# Nextcloud 顶层配置：启用多后端
$OCC config:system:set user_backend_default_value --value="user_ldap"

# user_saml 的两个核心开关（Nextcloud 30+）
$OCC saml:config:set "$SAML_IDP_ID" \
  general-allow_multiple_user_back_ends "1"
$OCC saml:config:set "$SAML_IDP_ID" \
  general-require_provisioned_account "1"

# 桌面客户端 SSO
$OCC saml:config:set "$SAML_IDP_ID" \
  general-use_saml_auth_for_desktop "1"

echo
echo "==> 4. 关闭 SAML 对用户属性的自动写入（让 LDAP 做唯一数据源）"
# 把这些 mapping 清空 → SAML 登录时不再覆盖 LDAP 的属性
for attr in displayName email quota groups; do
  $OCC saml:config:set "$SAML_IDP_ID" "saml-attribute-mapping-${attr}_mapping" ""
done
echo "   ✅ displayName / email / quota / groups 都从 LDAP 取"

echo
echo "==> 5. 确认 UID 映射对齐到 sAMAccountName"
echo "   当前 UID mapping ↓"
$OCC saml:config:get "$SAML_IDP_ID" | grep -i "uid_mapping" || true
echo
echo "   ⚠️  请人工确认上面的 claim 在 IdP 里返回的值就是 sAMAccountName"
echo "   (比如 jim.ma，不是 jim.ma@newegg.org，不是 displayName)"

echo
echo "==> 6. 显示最终 SAML 配置"
$OCC saml:config:get "$SAML_IDP_ID"

echo
echo "==> 7. 清理 SAML 历史孤儿账号（如果有）"
echo "   下面这些用户是 SAML 后端创建的（在 LDAP 启用之前），现在该不该清理？"
$OCC user:list --info 2>/dev/null | grep -i "user_saml" || echo "   ✅ 没有孤儿账号"

echo
echo "============================================================"
echo "✅ 配置完成。验证步骤："
echo "   1. 找一个全新的 AD 用户(从未登录过 Nextcloud)，确保他在 LDAP 同步范围内"
echo "   2. 让他走 SAML 登录"
echo "   3. 跑: $OCC user:list --info | grep <他的用户名>"
echo "      期望 backend 显示 'LDAP'，不是 'SAML'"
echo
echo "   反向测试："
echo "   1. 找一个 AD 里没有的用户（或不在 LDAP 过滤范围内），让他走 SAML"
echo "   2. 应该看到 'Account not provisioned' 错误页 → 这就对了"
echo "============================================================"
