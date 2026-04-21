#!/usr/bin/env bash
# ============================================================
# 一键修复 + 重新部署 LDAP + SAML 职责分离
#
# 修正点:
#   1. 用真正的服务账号密码 d9LbBYQBo&IdiXcJ
#   2. LDAP Internal Username 改为 mail (与 SAML 返回 email 对齐)
#   3. 配置 SAML 不自建账号、必须 LDAP 存在
#
# 假设上次 setup-ldap.sh 创建了 s01 配置但没激活
# ============================================================
set -euo pipefail

CONTAINER="nextcloud_app"
OCC="docker exec -u www-data ${CONTAINER} php occ"
SAML_IDP_ID="1"   # 如果你的 SAML idp ID 不是 1，修改这里

echo "==> [0] 清理上次失败的 LDAP 配置"
$OCC ldap:show-config | grep -E '^Configuration|s\d+' || true
read -rp "确认要删除现有 LDAP 配置 s01 并重建吗? [y/N]: " ans
if [[ "${ans,,}" == "y" ]]; then
  $OCC ldap:delete-config s01 2>/dev/null || true
  echo "   ✅ s01 已删除"
fi

echo
echo "==> [1] 重跑 LDAP 配置（用正确的密码和 mail UID）"
bash "$(dirname "$0")/setup-ldap.sh"

echo
echo "==> [2] 验证 LDAP 同步出真实用户"
USER_COUNT=$($OCC user:list 2>/dev/null | wc -l)
echo "   当前用户总数: $USER_COUNT"
if [[ "$USER_COUNT" -lt 1 ]]; then
  echo "❌ LDAP 没同步出用户，停止"
  exit 1
fi

echo "   样本（前 5 个）:"
$OCC user:list | head -5

echo
echo "==> [3] 配置 SAML：必须 LDAP 存在的用户才能登录"
$OCC saml:config:set "$SAML_IDP_ID" \
  general-allow_multiple_user_back_ends "1"
$OCC saml:config:set "$SAML_IDP_ID" \
  general-require_provisioned_account "1"
$OCC saml:config:set "$SAML_IDP_ID" \
  general-use_saml_auth_for_desktop "1"

echo
echo "==> [4] 关闭 SAML 的属性写入（让 LDAP 做唯一数据源）"
for attr in displayName email quota; do
  $OCC saml:config:set "$SAML_IDP_ID" \
    "saml-attribute-mapping-${attr}_mapping" "" 2>/dev/null || true
done

echo
echo "==> [5] 确认 SAML uid_mapping 指向 email claim"
echo "   ↓ 当前 SAML 配置的 uid_mapping："
$OCC saml:config:get "$SAML_IDP_ID" | grep -i "uid_mapping"
echo
echo "   ⚠️  请确认这是你 IdP 返回 email 的 claim 名"
echo "      ADFS:  http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
echo "      Azure: http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
echo "      Okta:  email 或 user.email"

echo
echo "============================================================"
echo "✅ 全部完成。验证："
echo
echo "   1. 共享框搜人："
echo "      Web 登录 admin → 任意文件右键 → 共享 → 输入同事邮箱前缀"
echo "      应该能搜到 AD 里所有人"
echo
echo "   2. 找一个新 AD 用户走 SAML 登录："
echo "      $OCC user:list --info | grep <用户邮箱>"
echo "      期望 backend 是 LDAP，不是 SAML"
echo
echo "   3. AD 里没有的用户走 SAML："
echo "      应该看到 'Account not provisioned' 错误"
echo "============================================================"
