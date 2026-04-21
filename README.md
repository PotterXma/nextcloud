# Nextcloud

部署服务器 : 172.16.160.231 e11ncloud01
访问地址 : https://nextcloud.newegg.org

基于 Docker Compose 的 Nextcloud 企业级私有云部署方案，面向 Newegg 内网环境。
已打通 **Azure AD SAML SSO + AD LDAP 用户同步 + 内网 SMTP** 三大体系。

---

## 目录

1. [架构概览](#架构概览)
2. [前置条件](#前置条件)
3. [快速部署](#快速部署)
4. [配置说明](#配置说明)
5. [SAML SSO 配置（Azure AD）](#saml-sso-配置azure-ad)
6. [LDAP / AD 用户与组同步](#ldap--ad-用户与组同步)
7. [LDAP 定时同步](#ldap-定时同步)
8. [员工离职处理流程](#员工离职处理流程)
9. [SMTP 邮件配置](#smtp-邮件配置)
10. [数据持久化](#数据持久化)
11. [运维操作](#运维操作)
12. [故障排查](#故障排查)
13. [安全事项与待办](#安全事项与待办)
14. [目录结构](#目录结构)

---

## 架构概览

```
                         ┌──────────────────┐
                         │   Load Balancer   │
                         │  (HTTPS 终止)     │
                         └────────┬─────────┘
                                  │ :443 → :8080
                    ┌─────────────┴─────────────┐
                    │      Docker Network        │
                    │      (nextcloud_net)       │
                    │                            │
          ┌─────────┴─────────┐                  │
          │   nextcloud_app   │◄── cron 容器     │
          │   (Nextcloud 33)  │   (定时任务)     │
          └──┬──────┬─────────┘                  │
             │      │                            │
      ┌──────┘      └──────┐                     │
      ▼                    ▼                     │
┌───────────┐      ┌──────────────┐              │
│  MariaDB  │      │    Redis     │              │
│  10.11    │      │  7 (Alpine)  │              │
└───────────┘      └──────────────┘              │
                                                 │
       外部依赖：                                 │
       ├── Azure AD (SAML IdP)                    │
       ├── AD / LDAP 10.1.37.133 (BUYABS.CORP)   │
       └── SMTP 中继 10.1.37.41:25                │
                    └────────────────────────────┘
```

| 服务 | 镜像 | 端口 | 用途 |
|------|------|------|------|
| `app` | `nextcloud:latest` (33.0.2.2) | `8080:80` | Nextcloud 主服务 |
| `db` | `mariadb:10.11` | internal | 数据库（binlog + ROW 格式） |
| `redis` | `redis:7-alpine` | internal | 分布式缓存 & 文件锁 |
| `cron` | `nextcloud:latest` | — | 后台定时任务（`/cron.sh`） |

> 所有镜像统一从内部 Registry `a.newegg.org/newegg-docker/` 拉取。

---

## 前置条件

- Docker Engine ≥ 20.10，Docker Compose ≥ 1.29（或 `docker compose` v2）
- 宿主机预创建目录：`/nextcloud-data`（用户数据挂载点）
- 负载均衡器已配置 HTTPS 终止，后端转发至 `:8080`
- DNS 解析：`nextcloud.newegg.org` → LB VIP
- **网络可达性**：
  - Nextcloud → `10.1.37.133:389` (AD LDAP)
  - Nextcloud → `10.1.37.41:25` (内网 SMTP)
  - Nextcloud ↔ `login.microsoftonline.com` (Azure AD)

---

## 快速部署

```bash
# 1. 克隆仓库
git clone <repo-url> && cd nextcloud

# 2. 创建宿主机数据目录
sudo mkdir -p /nextcloud-data

# 3. 修改密码（必须！见「安全事项」）
vim docker-compose.yaml

# 4. 启动全部服务
docker compose up -d

# 5. 检查健康状态
docker compose ps
docker compose logs -f app
```

首次启动约需 1-2 分钟完成数据库初始化和应用安装。访问 `https://nextcloud.newegg.org` 验证。

---

## 配置说明

配置文件采用 Nextcloud 的分片加载机制，`config/` 下每个 `.config.php` 独立管理一个功能模块。核心 `config.php` 由 Nextcloud 管理（`instanceid`、`passwordsalt`、`secret` 自动生成，**不要手动改**）。

当前生效的关键参数（`config/config.php`）：

```php
'overwritehost'      => 'nextcloud.newegg.org',
'overwriteprotocol'  => 'https',
'trusted_proxies'    => ['172.16.0.0/12'],
'trusted_domains'    => ['localhost', 'nextcloud.newegg.org'],
'memcache.local'     => '\\OC\\Memcache\\APCu',
'memcache.distributed' => '\\OC\\Memcache\\Redis',
'memcache.locking'   => '\\OC\\Memcache\\Redis',
'redis'              => ['host' => 'redis', 'port' => 6379],
'dbtype'             => 'mysql',
'dbhost'             => 'db',
'dbname'             => 'nextcloud',
'version'            => '33.0.2.2',
```

### 关键环境变量（`docker-compose.yaml`）

```yaml
NEXTCLOUD_TRUSTED_DOMAINS: nextcloud.newegg.org
OVERWRITEPROTOCOL: https
OVERWRITEHOST: nextcloud.newegg.org
TRUSTED_PROXIES: 172.16.0.0/12
PHP_MEMORY_LIMIT: 512M
PHP_UPLOAD_LIMIT: 10G
```

---

## SAML SSO 配置（Azure AD）

集成 `user_saml` v7.x（兼容 NC 30-33），IdP 是 **Azure AD / Microsoft Entra**。
企业内部 uid = 邮箱（`xxx@newegg.com`），由 SAML 的 `emailaddress` claim 承载。

### SP（Nextcloud）端点

| 端点 | URL |
|------|-----|
| Metadata | `https://nextcloud.newegg.org/apps/user_saml/saml/metadata` |
| ACS | `https://nextcloud.newegg.org/apps/user_saml/saml/acs` |
| SLS | `https://nextcloud.newegg.org/apps/user_saml/saml/sls` |
| Login | `https://nextcloud.newegg.org/apps/user_saml/saml/login` |

### Azure AD 端（摘要）

| 字段 | 值 |
|------|-----|
| 标识符（实体 ID） | `https://nextcloud.newegg.org/apps/user_saml/saml/metadata` |
| 回复 URL（ACS） | `https://nextcloud.newegg.org/apps/user_saml/saml/acs` |
| 注销 URL | `https://nextcloud.newegg.org/apps/user_saml/saml/sls` |
| IdP Entity ID | `https://sts.windows.net/b373f4fd-145d-419e-84f3-94a708ca5b3e/` |
| IdP SSO URL | `https://login.microsoftonline.com/{tenant-id}/saml2` |

**属性声明 / Claim**（必须返回邮箱，用作 uid）：

| Claim | 源属性 |
|-------|--------|
| `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress` | `user.mail` |
| `http://schemas.microsoft.com/identity/claims/displayname` | `user.displayname` |

### Nextcloud 端关键配置

UID mapping **必须指向邮箱 claim**（才能和 LDAP 里设置的 `ldapExpertUsernameAttr=mail` 对齐）：

```
general-uid_mapping = http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress
```

属性映射：

```
saml-attribute-mapping-displayName_mapping = http://schemas.microsoft.com/identity/claims/displayname
saml-attribute-mapping-email_mapping       = http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress
```

### 应用级（全局）开关 — 用 `config:app:set` 设置

> ⚠️ 这几个是 **app-level** 开关，不能用 `occ saml:config:set`（那是 per-provider 的）。

```bash
OCC='docker exec -u www-data nextcloud_app php occ'

# 1. 要求用户必须已被其他后端预建（关键：阻止 SAML 自动建号）
$OCC config:app:set user_saml general-require_provisioned_account --value=1

# 2. 允许同时启用多个用户后端（SAML + LDAP 共存）
$OCC config:app:set user_saml general-allow_multiple_user_back_ends --value=1

# 3. 允许桌面客户端用 SAML 登录
$OCC config:app:set user_saml general-use_saml_auth_for_desktop --value=1

# 校验
$OCC config:app:get user_saml general-require_provisioned_account
$OCC config:app:get user_saml general-allow_multiple_user_back_ends
$OCC config:app:get user_saml general-use_saml_auth_for_desktop
```

### 验证

```bash
# 导出 SP 元数据（给 Azure AD 做 SP 注册）
$OCC saml:metadata

# 查当前 IdP 配置
$OCC saml:config:get

# 用任意 AD 用户走一遍 SAML 登录，然后验证后端是 LDAP 而不是 SAML
$OCC user:list --info | grep -i '<邮箱前缀>'
# 期望: backend: LDAP
```

### SAML 故障排查

| 现象 | 原因 | 解决 |
|------|------|------|
| 登录后立即跳回登录页 | `trusted_domains` 缺失 | `config.php` 加入 `nextcloud.newegg.org` |
| SAML Response 验签失败 | 证书不匹配/过期 | 重新从 Azure 下载证书，更新 `idp-x509cert` |
| `Account not provisioned` | LDAP 没同步该用户 | 在 AD 里激活账号 → `$OCC user:sync --list -u user_ldap` |
| `404 /apps/user_saml/saml/acs` | 应用未启用 | `$OCC app:enable user_saml` |
| SSO 挂掉要救急 | 本地密码登录入口 | `https://nextcloud.newegg.org/login?direct=1` |

---

## LDAP / AD 用户与组同步

| 项目 | 值 |
|------|-----|
| AD 域 | `BUYABS.CORP` |
| LDAP Server | `ldap://10.1.37.133:389` |
| Service Account | `CN=rundecksvc,OU=ServiceAccounts,OU=ITIN,OU=Special Accounts,DC=buyabs,DC=corp` |
| Base DN | `DC=buyabs,DC=corp` |
| 当前同步规模 | **420 用户 / 3288 组** |

### 两个关键对齐：邮箱作为 uid，objectGUID 作为 UUID

```
ldapExpertUsernameAttr = mail          # Internal Username 用邮箱
ldapExpertUUIDUserAttr = objectGUID    # 稳定 UUID（改名/迁 OU 不断）
ldapEmailAttribute     = mail
ldapUserDisplayName    = displayName
```

**为什么 `ldapExpertUsernameAttr=mail`？**
因为 SAML 返回的是邮箱，LDAP 的 Internal Username 也用邮箱，两边 uid 完全一致，SAML 登录时就能直接命中 LDAP 账号，不会重复建号。

### 过滤器

```
# 用户：排除被禁用的 AD 账号（userAccountControl bit 0x2）
ldapUserFilter  = (&(objectClass=user)(objectCategory=person)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))

# 登录：支持 sAMAccountName 或 邮箱
ldapLoginFilter = (&(objectClass=user)(objectCategory=person)(|(sAMAccountName=%uid)(mail=%uid)))

# 组：拉取所有 AD 安全组
ldapGroupFilter = (&(objectClass=group))
```

### 首次部署流程

部署脚本在 `E:\Work\nextcloud\`：

```bash
# 1. 连通性 & 绑定测试（先跑这个）
bash test-ldap.sh

# 2. 正式写配置
bash setup-ldap.sh                # 新建配置
bash setup-ldap.sh s01            # 或更新已有配置
```

脚本自动完成：`ldap:create-empty-config` → 写服务器参数 → 写过滤器 → 写属性映射 → `ldap:test-config` → 激活。

### 常用运维命令

```bash
OCC='docker exec -u www-data nextcloud_app php occ'

# 查看所有 LDAP 配置
$OCC ldap:show-config

# 测试配置连通性
$OCC ldap:test-config s01

# 对某个 UID 在 LDAP 端查询
$OCC ldap:search --limit 5000 'suntek.q.ma'

# 手动触发增量同步（立刻跑一次后台同步队列）
docker exec -u www-data nextcloud_app php -f cron.php

# 检查由于在 AD 中被删除或禁用而产生的遗留账号
$OCC ldap:show-remnants

# 统计用户 / 组
$OCC user:list | wc -l          # 420
$OCC group:list | wc -l         # 3288
$OCC user:list --info | grep 'backend: ' | sort | uniq -c
```

### 清理遗留的 SAML 孤儿 / LDAP `_NNNN` 后缀账号

早期（`require_provisioned_account=0` 时代）SAML 直接 auto-provision 过一批 user_saml 账号；LDAP 后来同步时撞名，被迫加 `_NNNN` 后缀。**正确清理方法**：

```bash
# 对某个有 _NNNN 后缀的 LDAP 账号
OCC="docker exec -i -u www-data nextcloud_app bash -c"

# ldap:reset-user 会自动处理 mapping，不会再触发撞名
$OCC 'yes y | php occ ldap:reset-user Suntek.Q.Ma@newegg.com_3117'

# 对 user_saml 后端的孤儿（先检查数据，再删）
$OCC 'php occ user:list --info | grep -B1 "backend: user_saml"'
$OCC 'php occ user:delete <uid>'
```

> **不要用 `maintenance:mode --on`** 做清理 — 维护模式下后端会被禁用，`user:delete` 会失败。

### 回滚 LDAP 配置

```bash
OCC='docker exec -u www-data nextcloud_app php occ'

# 1. 先失活
$OCC ldap:set-config s01 ldapConfigurationActive 0

# 2. 删除配置
$OCC ldap:delete-config s01

# 3.（可选）禁用整个 user_ldap 应用
$OCC app:disable user_ldap
```

> ⚠️ LDAP 后端创建的用户记录不会自动删除：他们的 backend 会变成 `missing`，共享和文件仍在数据库里。需要彻底清理时用 `$OCC user:delete <username>`。

### 已知的日志噪音

`nextcloud.log` 里会周期性出现：

```
Undefined array key "mail" ... at lib/User/Backend.php ... Access.php:555
```

来源是 AD 里有 **少数账号没有 `mail` 属性**（多半是服务账号 / 空壳账号）。不影响功能。彻底消除需要：

- 方案 A：在 `ldapUserFilter` 加上 `(mail=*)`，只同步有邮箱的账号 — 风险是会漏掉合法但暂时没邮箱的用户
- 方案 B：等 user_ldap 上游修复 `#44xxx`
- 当前：**忽略**

---

## LDAP 定时同步

> **Docker Compose 环境怎么跑定时任务？**
> 脚本通过 `docker exec` 操作容器，所以直接在 **宿主机 crontab** 调度即可，不需要改 `docker-compose.yaml`。

### 部署脚本

```bash
# 运行一键配置脚本
bash setup-cron.sh
```

### 配置宿主机 crontab

```bash
crontab -e
```

添加：

```cron
# Nextcloud LDAP 增量同步 - 每小时
0 * * * *   /bin/bash /opt/nextcloud/ldap-sync.sh        >> /var/log/nc-ldap.log 2>&1

# Nextcloud LDAP 全量同步 - 每天凌晨 2 点（自动 disable 离职账号 + 邮件通知）
0 2 * * *   /bin/bash /opt/nextcloud/ldap-sync.sh full   >> /var/log/nc-ldap.log 2>&1
```

### 两种模式

| 模式 | 命令 | 说明 |
|------|------|------|
| 增量 | `ldap-sync.sh` | 触发 `cron.php` 跑一轮，拉新用户、更新属性 |
| 全量 | `ldap-sync.sh full` | 触发同步并检查 `ldap:show-remnants`，将 AD 里已禁用/删除的账号在 NC 端自动 disable |

### 邮件通知

全量同步完成后，脚本会通过内网 SMTP（`10.1.37.41:25`）自动发送报告邮件至 admin 组（`ITInfrastructureTeam@newegg.com`），内容包括：
- 用户/组统计
- 本次新增禁用的账号列表
- 如有新增禁用，邮件标题会标记 ⚠️ 醒目提示

收件人在脚本顶部 `MAIL_TO` 变量修改。

### 日志

```bash
# 查看同步日志
tail -100 /var/log/nc-ldap.log

# 手动执行一次全量同步测试
bash /opt/nextcloud/ldap-sync.sh full
```

---

## 员工离职处理流程

### 整体流程

```
员工离职
  │
  ├─ 自动路径（无需人工）
  │   └─ AD 端禁用账号 → ldap-sync.sh full (凌晨 cron)
  │       → 查出 ldap:show-remnants (AD已不存在的用户)
  │       → NC 账号自动 disable（数据保留，登录拒绝）
  │       → 📧 邮件通知 admin 组
  │
  └─ 手动路径（需要文件交接时）
      └─ bash offboard-user.sh leaver@newegg.com manager@newegg.com
          ├─ files:transfer-ownership → 文件交接
          ├─ user:disable → 封禁登录
          ├─ 📧 邮件通知 admin 组
          └─ 30-90 天保留期后 → user:delete 彻底删除
```

### 使用方式

```bash
# 如果已经跑过 setup-cron.sh，脚本会在 /opt/nextcloud 下

# 只禁用（不交接文件）
bash /opt/nextcloud/offboard-user.sh leaver@newegg.com

# 禁用 + 文件交接给继任者
bash /opt/nextcloud/offboard-user.sh leaver@newegg.com manager@newegg.com
```

### 脚本执行步骤

1. **校验用户存在** — 确认 UID 有效
2. **文件交接**（可选）— `files:transfer-ownership`，继任者的 `files/` 下会多一个 `transferred from xxx/` 目录
3. **禁用账号** — `user:disable`，登录立即被拒
4. **邮件通知** — 自动发送至 admin 组，包含用户信息、数据大小、交接状态、后续待办

### 邮件通知内容

离职处理完成后自动发送邮件（`10.1.37.41:25`），包含：
- 离职员工 UID 和数据大小
- 文件交接状态
- 后续待办清单（AD 端确认、审计、数据删除时间表）

### 彻底删除（保留期结束后）

```bash
OCC='docker exec -u www-data nextcloud_app php occ'

# 删除用户（连同所有数据）
$OCC user:delete leaver@newegg.com

# 清除 LDAP mapping 残留
$OCC ldap:reset-user leaver@newegg.com
```

> [!CAUTION]
> `user:delete` 会永久删除该用户的所有文件、共享和设置，且**不可逆**。请确认已过数据保留期。

---

## SMTP 邮件配置

| 项 | 值 |
|-----|-----|
| SMTP Server | `10.1.37.41:25` |
| 认证 | **无**（内网 IP 白名单） |
| TLS | 关闭（普通 25 端口） |
| `mail_from_address` | `nextcloud` |
| `mail_domain` | `newegg.com` |
| 系统邮件发件人 | `nextcloud@newegg.com` |

### 配置命令（已执行）

```bash
OCC='docker exec -u www-data nextcloud_app php occ'

$OCC config:system:set mail_smtpmode     --value=smtp
$OCC config:system:set mail_sendmailmode --value=smtp
$OCC config:system:set mail_smtphost     --value=10.1.37.41
$OCC config:system:set mail_smtpport     --value=25
$OCC config:system:set mail_smtpauthtype --value=LOGIN
$OCC config:system:set mail_smtpauth     --value=false --type=boolean
$OCC config:system:set mail_smtpsecure   --value=""
$OCC config:system:set mail_smtpname     --value=""
$OCC config:system:set mail_smtppassword --value=""
$OCC config:system:set mail_from_address --value=nextcloud
$OCC config:system:set mail_domain       --value=newegg.com
```

> 注意 `mail_smtpauth` 必须是 **literal `false`**（配合 `--type=boolean`），不能写 `0` — occ 会报 *Unable to parse value as boolean*。

### 测试

**Web UI** — 管理设置 → 基本设置 → 邮件服务器 → 「发送邮件」。

**容器内快速自测**：

```bash
docker exec nextcloud_app bash -c '
  echo -e "EHLO nextcloud.newegg.org\nQUIT" | nc 10.1.37.41 25
'
```

### SMTP 故障排查

| 现象 | 排查 |
|------|------|
| 测试邮件超时 | `telnet 10.1.37.41 25` 确认容器能出网；`iptables -nL` on 10.1.37.41 放行源 IP |
| `550 Sender rejected` | `mail_domain` / `mail_from_address` 和 SMTP Relay 允许发件策略不匹配 |
| 邮件没到但日志无报错 | Exchange 里收件人是否在拒收列表 / 邮件归到垃圾箱 |

---

## 数据持久化

### Volumes 总览

| 宿主机路径 | 容器内路径 | 类型 | 说明 | 需备份 |
|------------|-----------|------|------|--------|
| `db_data` (named) | `/var/lib/mysql` | Docker volume | MariaDB 数据文件（所有表、索引、binlog） | ✅ 用 `mysqldump` |
| `nextcloud_data` (named) | `/var/www/html` | Docker volume | Nextcloud PHP 程序文件、内置应用 | ❌ 镜像自带，升级会重建 |
| `/nextcloud-data` | `/var/www/html/data` | Bind mount | **用户上传的所有文件**，按 `data/<uid>/files/` 存储；也包含 `nextcloud.log` | ✅ 最重要 |
| `./config` | `/var/www/html/config` | Bind mount | PHP 配置片段（`config.php` + 各模块 `.config.php`），Git 管理 | ✅ Git 已跟踪 |
| `./custom_apps` | `/var/www/html/custom_apps` | Bind mount | 手动安装的第三方应用（如 `user_saml`），Git 管理 | ✅ Git 已跟踪 |

> `app` 和 `cron` 两个容器共享完全相同的 volume 挂载，确保 cron 任务能访问同一份数据和配置。

### 用户文件存储结构

```
/nextcloud-data/                        # 宿主机
├── admin/
│   └── files/                          # admin 用户的文件
│       ├── Documents/
│       └── Photos/
├── Suntek.Q.Ma@newegg.com/
│   └── files/                          # LDAP 用户的文件（uid = 邮箱）
├── appdata_xxxxxxxxxx/                 # Nextcloud 内部应用数据
├── nextcloud.log                       # 应用日志
└── .ocdata                             # Nextcloud 数据目录标记文件
```

### Named Volume vs Bind Mount

- **Named Volume**（`db_data`、`nextcloud_data`）：由 Docker 管理，数据在宿主机 `/var/lib/docker/volumes/<name>/_data/`，不建议直接操作
- **Bind Mount**（`/nextcloud-data`、`./config`、`./custom_apps`）：直接映射宿主机目录，方便备份和 Git 管理

> [!IMPORTANT]
> `/nextcloud-data` 必须在部署前预创建，且权限需允许容器内 `www-data`（uid 33）读写：
> ```bash
> sudo mkdir -p /nextcloud-data
> sudo chown 33:33 /nextcloud-data
> ```

---

## 运维操作

### 常用 occ 命令

```bash
alias occ='docker exec -u www-data nextcloud_app php occ'

# 状态 / 升级
occ status
occ upgrade

# 维护模式
occ maintenance:mode --on
occ maintenance:mode --off

# 文件扫描
occ files:scan --all
occ files:scan <username>

# DB 维护
occ db:add-missing-indices
occ db:add-missing-columns
occ db:convert-filecache-bigint

# LDAP / SAML / SMTP 见上文对应章节
```

### 备份

```bash
# 1. 进入维护模式
docker exec -u www-data nextcloud_app php occ maintenance:mode --on

# 2. 备份数据库
docker exec nextcloud_db mysqldump -u root -p'<ROOT_PASSWORD>' nextcloud \
  > backup_$(date +%F).sql

# 3. 备份用户数据
tar -czf nextcloud-data_$(date +%F).tar.gz /nextcloud-data

# 4. 备份配置（其实 git 里已经有了）
tar -czf config_$(date +%F).tar.gz config/ custom_apps/

# 5. 退出维护模式
docker exec -u www-data nextcloud_app php occ maintenance:mode --off
```

### 升级 Nextcloud

```bash
docker compose pull app cron
docker compose up -d app cron
docker exec -u www-data nextcloud_app php occ upgrade
docker exec -u www-data nextcloud_app php occ db:add-missing-indices
```

---

## 故障排查

```bash
# 容器日志
docker compose logs -f app

# Nextcloud 内部日志
docker exec nextcloud_app tail -200 /var/www/html/data/nextcloud.log

# 实时看 SAML / LDAP 相关日志
docker exec nextcloud_app tail -f /var/www/html/data/nextcloud.log \
  | grep -iE 'saml|ldap|smtp'

# 数据库连接
docker exec nextcloud_db mysql -u nextcloud -p'<PASSWORD>' -e 'SELECT 1'

# Redis 连接
docker exec nextcloud_redis redis-cli ping

# 修文件权限
docker exec nextcloud_app chown -R www-data:www-data /var/www/html/data
```

---

## 安全事项与待办

### 部署期强制项

> [!CAUTION]
> `docker-compose.yaml` 和 `config/config.php` 中包含数据库密码等占位值。
> **部署前必须改为强密码，真实凭据不要进 Git。**

- 用 `.env` + `env_file:` 管理敏感信息，`.env` 加入 `.gitignore`
- `config.php` 的 `passwordsalt` / `secret` / `instanceid` 首次安装自动生成，**不要手改**
- LDAP Service Account (`rundecksvc`) 密码明文出现在 `setup-ldap.sh` — 部署完毕应从脚本清掉，或 `chmod 600`

### 待办清单

| 优先级 | 项 | 说明 |
|--------|-----|------|
| 高 | 轮换 `rundecksvc` 密码 | 当前密码 `setup-ldap.sh` 里是明文，历史残留 |
| 高 | LDAP 改走 LDAPS (636) | 现在走 389，明文传 bind password |
| 中 | 给本地 admin 账号重置邮箱 | 避免和 LDAP 内的 Suntek.Q.Ma 语义混淆 |
| 中 | 配置自动备份（DB + 用户数据） | 每日增量 + 每周全量 |
| 中 | 清理 `Undefined array key "mail"` 日志噪音 | 见 LDAP 章节 |
| 低 | 给 LDAP 同步的 Suntek 加入 admin 组 | 目前只有本地 admin 是管理员 |
| 低 | SAML 签名强化 | `security-authnRequestsSigned=1`、`wantAssertionsSigned=1` |

---

## 目录结构

```
nextcloud/
├── docker-compose.yaml          # 服务编排
├── README.md                    # 本文件
├── ldap-sync.sh                 # LDAP 定时同步（宿主机 cron 调用）
├── offboard-user.sh             # 员工离职处理（disable + 文件交接 + 邮件通知）
├── config/                      # Nextcloud PHP 配置片段
│   ├── config.php               # 主配置（Nextcloud 管理 + 运维维护）
│   ├── redis.config.php
│   ├── s3.config.php
│   ├── smtp.config.php
│   ├── reverse-proxy.config.php
│   ├── apache-pretty-urls.config.php
│   ├── apcu.config.php
│   └── apps.config.php
├── custom_apps/                 # 第三方应用
│   └── user_saml/               # SAML SSO 插件 v7.x
└── data/                        # 运行时 - nextcloud.log 等（bind）
```
