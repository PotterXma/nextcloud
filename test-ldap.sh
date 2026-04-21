#!/usr/bin/env bash
# ============================================================
# Nextcloud → AD (BUYABS.CORP) 连通性测试
# 在跑 setup-ldap.sh 之前，先用这个脚本验证：
#   1. Nextcloud 容器能不能解析/访问 AD
#   2. 服务账号能不能 bind
#   3. 能不能在 base DN 下搜到真实用户
# ============================================================
set -euo pipefail

CONTAINER="nextcloud_app"

LDAP_HOST="10.1.37.133"
LDAP_PORT="389"
LDAP_URI="ldap://${LDAP_HOST}:${LDAP_PORT}"
LDAP_AGENT_DN='CN=rundecksvc,OU=ServiceAccounts,OU=ITIN,OU=Special Accounts,DC=buyabs,DC=corp'
LDAP_AGENT_PWD='newegg@123'
LDAP_BASE_DN='DC=buyabs,DC=corp'

echo "==> [1/4] 检查容器是否运行"
docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$" \
  || { echo "❌ 容器 ${CONTAINER} 没在运行"; exit 1; }
echo "   ✅ ${CONTAINER} 在运行"

echo
echo "==> [2/4] 在容器里安装 ldap-utils（如未安装）"
docker exec -u root "${CONTAINER}" bash -c '
  if ! command -v ldapsearch >/dev/null; then
    apt-get update -qq && apt-get install -y -qq ldap-utils >/dev/null
  fi
  ldapsearch -VV 2>&1 | head -1
'

echo
echo "==> [3/4] 测试 TCP 连通性 ${LDAP_HOST}:${LDAP_PORT}"
docker exec "${CONTAINER}" bash -c "
  timeout 5 bash -c '</dev/tcp/${LDAP_HOST}/${LDAP_PORT}' \
    && echo '   ✅ TCP 通' \
    || { echo '   ❌ TCP 不通，检查防火墙/路由'; exit 1; }
"

echo
echo "==> [4/4] 用服务账号做 bind + 搜索"
docker exec "${CONTAINER}" bash -c "
  ldapsearch -x -LLL \
    -H '${LDAP_URI}' \
    -D '${LDAP_AGENT_DN}' \
    -w '${LDAP_AGENT_PWD}' \
    -b '${LDAP_BASE_DN}' \
    -s base '(objectClass=*)' namingContexts dnsHostName 2>&1 | head -20
"

echo
echo "==> 额外：搜一个真实用户（请改下面的 sAMAccountName）"
TEST_USER="${1:-suntek.q.ma}"
docker exec "${CONTAINER}" bash -c "
  echo '   搜索: ${TEST_USER}'
  ldapsearch -x -LLL \
    -H '${LDAP_URI}' \
    -D '${LDAP_AGENT_DN}' \
    -w '${LDAP_AGENT_PWD}' \
    -b '${LDAP_BASE_DN}' \
    '(sAMAccountName=${TEST_USER})' \
    dn cn mail sAMAccountName memberOf 2>&1 | head -30
"

echo
echo "✅ 测试完成。如果上面能看到你的 dn / cn / mail，说明 LDAP 完全打通，可以跑 setup-ldap.sh"
