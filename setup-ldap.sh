#!/usr/bin/env bash
# ============================================================
# Nextcloud LDAP/AD 自动配置脚本
# 目标 AD: 10.1.37.133 (BUYABS.CORP)
# 服务账号: rundecksvc
#
# 用法:
#   bash setup-ldap.sh           # 创建新配置
#   bash setup-ldap.sh s01       # 更新已有的配置 ID
#
# 前置条件:
#   1. 先跑 test-ldap.sh 全部通过
#   2. user_saml 已经在跑（可选，但本脚本会同时配 SAML 兼容）
# ============================================================
set -euo pipefail

CONTAINER="nextcloud_app"
OCC="docker exec -u www-data ${CONTAINER} php occ"

# ---- AD 连接参数 ----
LDAP_HOST="ldap://10.1.37.133"
LDAP_PORT=389
LDAP_AGENT_DN='CN=rundecksvc,OU=ServiceAccounts,OU=ITIN,OU=Special Accounts,DC=buyabs,DC=corp'
LDAP_AGENT_PWD='newegg@123'
LDAP_BASE_DN='DC=buyabs,DC=corp'

# ---- 用户/组过滤器（按需调整）----
# 默认：所有"启用的"AD 用户账号
# userAccountControl:1.2.840.113556.1.4.803:=2  →  account is DISABLED
# !(...:=2) 表示排除被停用的账号
LDAP_USER_FILTER='(&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))'

# 默认：登录支持 sAMAccountName 或 邮箱
LDAP_LOGIN_FILTER='(&(objectClass=user)(objectCategory=person)(|(sAMAccountName=%uid)(mail=%uid)))'

# 默认：所有 AD 安全组
LDAP_GROUP_FILTER='(&(objectClass=group))'

# ============================================================

echo "==> [1] 启用 user_ldap 应用"
$OCC app:enable user_ldap

echo
echo "==> [2] 决定使用的配置 ID"
if [[ $# -ge 1 ]]; then
  CONFIG_ID="$1"
  echo "    使用现有配置 ID: ${CONFIG_ID}"
else
  CONFIG_ID=$($OCC ldap:create-empty-config | grep -oP 's\d+' || true)
  if [[ -z "$CONFIG_ID" ]]; then
    # 兼容输出格式不同的版本
    CONFIG_ID=$($OCC ldap:show-config | grep -oP 's\d+' | head -1)
  fi
  echo "    新建配置 ID: ${CONFIG_ID}"
fi

set_cfg() {
  local key="$1" val="$2"
  $OCC ldap:set-config "$CONFIG_ID" "$key" "$val"
}

echo
echo "==> [3] 写入服务器连接参数"
set_cfg ldapHost          "$LDAP_HOST"
set_cfg ldapPort          "$LDAP_PORT"
set_cfg ldapAgentName     "$LDAP_AGENT_DN"
set_cfg ldapAgentPassword "$LDAP_AGENT_PWD"
set_cfg ldapBase          "$LDAP_BASE_DN"
set_cfg ldapBaseUsers     "$LDAP_BASE_DN"
set_cfg ldapBaseGroups    "$LDAP_BASE_DN"
set_cfg turnOffCertCheck  "0"

echo
echo "==> [4] 用户过滤器 / 登录过滤器"
set_cfg ldapUserFilter            "$LDAP_USER_FILTER"
set_cfg ldapUserFilterMode        "1"            # 1 = raw filter
set_cfg ldapUserFilterObjectclass "user"
set_cfg ldapLoginFilter           "$LDAP_LOGIN_FILTER"
set_cfg ldapLoginFilterMode       "1"
set_cfg ldapLoginFilterAttributes "sAMAccountName;mail"
set_cfg ldapLoginFilterUsername   "1"
set_cfg ldapLoginFilterEmail      "1"

echo
echo "==> [5] 组过滤器"
set_cfg ldapGroupFilter            "$LDAP_GROUP_FILTER"
set_cfg ldapGroupFilterMode        "1"
set_cfg ldapGroupFilterObjectclass "group"
set_cfg ldapGroupMemberAssocAttr   "member"
set_cfg useMemberOfToDetectMembership "1"

echo
echo "==> [6] 与 SAML 对齐的关键配置"
# 让 Nextcloud 内部 username = AD 的 sAMAccountName
# SAML 那边要保证 NameID/uid claim 也是 sAMAccountName
set_cfg ldapExpertUsernameAttr  "sAMAccountName"
set_cfg ldapExpertUUIDUserAttr  "objectGUID"
set_cfg ldapExpertUUIDGroupAttr "objectGUID"

echo
echo "==> [7] 显示名 / 邮箱属性"
set_cfg ldapEmailAttribute   "mail"
set_cfg ldapUserDisplayName  "displayName"
set_cfg ldapGroupDisplayName "cn"

echo
echo "==> [8] 性能/缓存"
set_cfg ldapCacheTTL              "600"
set_cfg ldapPagingSize            "500"
set_cfg ldapNestedGroups          "0"
set_cfg ldapTLS                   "0"

echo
echo "==> [9] 测试配置"
set +e
$OCC ldap:test-config "$CONFIG_ID"
TEST_RC=$?
set -e
if [[ $TEST_RC -ne 0 ]]; then
  echo "❌ 测试未通过，检查上面的报错。配置未激活。"
  exit 1
fi

echo
echo "==> [10] 激活配置"
set_cfg ldapConfigurationActive "1"

echo
echo "==> [11] 当前所有 LDAP 配置"
$OCC ldap:show-config

echo
echo "==> [12] 同步样本（前 5 个用户 / 组）"
$OCC user:list | head -5 || true
echo "---"
$OCC group:list | head -5 || true

echo
echo "✅ 完成！下一步："
echo "   1. 在 Web UI: 管理设置 → SSO & SAML authentication"
echo "      - 勾选 'Allow the use of multiple user back-ends (SSO & LDAP)'"
echo "      - 勾选 'Only allow authentication if an account exists on some other backend'"
echo "   2. 找一个新 AD 用户走一次 SAML 登录，验证不会被建成重复账号"
echo "   3. 验证：${OCC} user:list --info | grep -i <用户名>"
echo "      backend 应该是 LDAP，不是 SAML"
