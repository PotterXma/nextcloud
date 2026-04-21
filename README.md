# Nextcloud
部署服务器 : 172.16.160.231
访问地址 : https://nextcloud.newegg.org



基于 Docker Compose 的 Nextcloud 企业级私有云部署方案，面向 Newegg 内网环境。

## 架构概览

```
                         ┌──────────────────┐
                         │   Load Balancer   │
                         │  (HTTPS 终止)     │
                         └────────┬─────────┘
                                  │ :443 → :8080
                    ┌─────────────┴─────────────┐
                    │      Docker Network        │
                    │      (nextcloud_net)        │
                    │                             │
          ┌─────────┴─────────┐                   │
          │   nextcloud_app   │◄─── cron 容器      │
          │   (Nextcloud 33)  │    (定时任务)       │
          └──┬──────┬─────────┘                   │
             │      │                             │
      ┌──────┘      └──────┐                      │
      ▼                    ▼                      │
┌───────────┐      ┌──────────────┐               │
│  MariaDB  │      │    Redis     │               │
│  10.11    │      │  7 (Alpine)  │               │
└───────────┘      └──────────────┘               │
                                                  │
        数据持久化:                                │
        ├── db_data (volume)    → MariaDB 数据      │
        ├── nextcloud_data (volume) → 应用文件       │
        ├── /nextcloud-data (bind) → 用户文件        │
        ├── ./config (bind)     → PHP 配置片段       │
        └── ./custom_apps (bind)→ 自定义应用          │
                    └─────────────────────────────┘
```

| 服务 | 镜像 | 端口 | 用途 |
|------|------|------|------|
| `app` | `nextcloud:latest` | `8080:80` | Nextcloud 主服务 |
| `db` | `mariadb:10.11` | internal | 数据库（binlog + ROW 格式） |
| `redis` | `redis:7-alpine` | internal | 分布式缓存 & 文件锁 |
| `cron` | `nextcloud:latest` | — | 后台定时任务（`/cron.sh`） |

> 所有镜像统一从内部 Registry `a.newegg.org/newegg-docker/` 拉取。

## 前置条件

- Docker Engine ≥ 20.10
- Docker Compose ≥ 1.29（或 `docker compose` v2）
- 宿主机预创建目录：`/nextcloud-data`（用户数据挂载点）
- 负载均衡器已配置 HTTPS 终止，后端转发至 `:8080`
- DNS 解析：`nextcloud.newegg.org` → LB VIP

## 快速部署

```bash
# 1. 克隆仓库
git clone <repo-url> && cd nextcloud

# 2. 创建宿主机数据目录
sudo mkdir -p /nextcloud-data

# 3. 修改密码（必须！见下方「安全事项」）
vim docker-compose.yaml

# 4. 启动全部服务
docker compose up -d

# 5. 检查健康状态
docker compose ps
docker compose logs -f app
```

首次启动约需 1-2 分钟完成数据库初始化和应用安装。访问 `https://nextcloud.newegg.org` 验证。

## 配置说明

配置文件采用 Nextcloud 的 [分片加载机制](https://docs.nextcloud.com/server/latest/admin_manual/configuration_server/config_sample_php_parameters.html)，`config/` 下每个 `.config.php` 文件独立管理一个功能模块：

| 文件 | 功能 | 关键参数 |
|------|------|----------|
| `config.php` | 主配置 | 数据库连接、trusted_domains、缓存 |
| `redis.config.php` | Redis 缓存 | `REDIS_HOST`、分布式锁 |
| `s3.config.php` | S3 对象存储 | `OBJECTSTORE_S3_*` 环境变量驱动 |
| `smtp.config.php` | 邮件发送 | `SMTP_HOST`、`MAIL_FROM_ADDRESS`、`MAIL_DOMAIN` |
| `reverse-proxy.config.php` | 反向代理适配 | `OVERWRITEPROTOCOL`、`TRUSTED_PROXIES` |
| `apache-pretty-urls.config.php` | URL 美化 | `.htaccess` rewrite |
| `apcu.config.php` | 本地缓存 | APCu memcache |
| `apps.config.php` | 应用路径 | `/apps` + `/custom_apps` |

### 关键环境变量

在 `docker-compose.yaml` 中配置：

```yaml
# 反向代理 / LB
NEXTCLOUD_TRUSTED_DOMAINS: nextcloud.newegg.org
OVERWRITEPROTOCOL: https
OVERWRITEHOST: nextcloud.newegg.org
TRUSTED_PROXIES: 172.16.0.0/12

# PHP 性能
PHP_MEMORY_LIMIT: 512M
PHP_UPLOAD_LIMIT: 10G
```

### S3 对象存储（可选）

如需将文件存储迁移至 S3 兼容后端，设置以下环境变量：

```yaml
OBJECTSTORE_S3_BUCKET: nextcloud
OBJECTSTORE_S3_HOST: s3.newegg.org
OBJECTSTORE_S3_KEY: <access-key>
OBJECTSTORE_S3_SECRET: <secret-key>
OBJECTSTORE_S3_REGION: us-east-1
OBJECTSTORE_S3_USEPATH_STYLE: "true"   # MinIO / 非 AWS 需要
```

### SMTP 邮件（可选）

```yaml
SMTP_HOST: 10.1.37.41
SMTP_PORT: 25
MAIL_FROM_ADDRESS: nextcloud
MAIL_DOMAIN: newegg.com
```

## 自定义应用

`custom_apps/` 目录挂载到容器内 `/var/www/html/custom_apps`，可写入第三方应用。

当前已安装：

| 应用 | 用途 |
|------|------|
| `user_saml` | SAML SSO 单点登录（Azure AD 集成） |

安装新应用：
```bash
# 方式一：通过 occ 命令
docker exec -u www-data nextcloud_app php occ app:install <app-name>

# 方式二：手动下载解压到 custom_apps/
tar -xzf <app>.tar.gz -C custom_apps/
docker exec -u www-data nextcloud_app php occ app:enable <app-name>
```

## SAML SSO 配置

已集成 `user_saml` v7.1.4 应用（兼容 Nextcloud 30-33），支持 Azure AD SAML 2.0 认证。

### SP（Nextcloud）端点

| 端点 | URL | 用途 |
|------|-----|------|
| Metadata | `https://nextcloud.newegg.org/apps/user_saml/saml/metadata` | SP 元数据（XML），Azure AD 注册时填入 |
| ACS | `https://nextcloud.newegg.org/apps/user_saml/saml/acs` | Assertion Consumer Service（POST） |
| SLS | `https://nextcloud.newegg.org/apps/user_saml/saml/sls` | Single Logout Service（GET/POST） |
| Login | `https://nextcloud.newegg.org/apps/user_saml/saml/login` | SSO 登录入口 |

### Step 1：Azure AD 配置

1. **Azure Portal → 企业应用程序 → 新建应用程序 → 创建你自己的应用程序**
2. 进入应用 → **单一登录 → SAML**
3. 基本 SAML 配置：

   | 字段 | 值 |
   |------|-----|
   | 标识符（实体 ID） | `https://nextcloud.newegg.org/apps/user_saml/saml/metadata` |
   | 回复 URL（ACS） | `https://nextcloud.newegg.org/apps/user_saml/saml/acs` |
   | 注销 URL | `https://nextcloud.newegg.org/apps/user_saml/saml/sls` |

4. **属性和声明** — 配置以下映射：

   | 声明名称 | 源属性 | Nextcloud 映射字段 |
   |----------|--------|-------------------|
   | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name` | `user.userprincipalname` | uid |
   | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress` | `user.mail` | email |
   | `http://schemas.microsoft.com/identity/claims/displayname` | `user.displayname` | displayName |
   | `http://schemas.microsoft.com/ws/2008/06/identity/claims/groups` | `user.groups` | groups（可选） |

5. **下载**：
   - **证书（Base64）** → 后续填入 Nextcloud IdP x509cert
   - 记录 **登录 URL** 和 **Azure AD 标识符**

### Step 2：Nextcloud 配置

#### 方式一：Web UI

管理设置 → **SSO & SAML 认证**：

| 配置项 | 值 |
|--------|-----|
| SSO 类型 | SAML |
| 显示名称 | `Azure AD SSO` |
| UID 映射 | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name` |
| IdP Entity ID | `https://sts.windows.net/{tenant-id}/` |
| IdP SSO URL | `https://login.microsoftonline.com/{tenant-id}/saml2` |
| IdP SLO URL | `https://login.microsoftonline.com/{tenant-id}/saml2` |
| IdP x509 证书 | （粘贴 Azure 下载的 Base64 证书内容） |

属性映射：

| 字段 | Claim URI |
|------|-----------|
| displayName | `http://schemas.microsoft.com/identity/claims/displayname` |
| email | `http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress` |

#### 方式二：occ 命令行

```bash
# 创建 SAML Provider（返回 provider ID）
docker exec -u www-data nextcloud_app php occ saml:config:create

# 设置 IdP 参数（假设 provider ID = 1）
docker exec -u www-data nextcloud_app php occ saml:config:set \
  --general-idp0_display_name="Azure AD SSO" \
  --general-uid_mapping="http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name" \
  --idp-entityId="https://sts.windows.net/{tenant-id}/" \
  --idp-singleSignOnService.url="https://login.microsoftonline.com/{tenant-id}/saml2" \
  --idp-singleLogoutService.url="https://login.microsoftonline.com/{tenant-id}/saml2" \
  --idp-x509cert="$(cat /path/to/azure-cert.pem)" \
  1

# 设置属性映射
docker exec -u www-data nextcloud_app php occ saml:config:set \
  --saml-attribute-mapping-displayName_mapping="http://schemas.microsoft.com/identity/claims/displayname" \
  --saml-attribute-mapping-email_mapping="http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress" \
  1

# 查看当前配置
docker exec -u www-data nextcloud_app php occ saml:config:get

# 导出 SP 元数据（用于 Azure AD 注册）
docker exec -u www-data nextcloud_app php occ saml:metadata
```

### Step 3：全局设置

```bash
# 设置 SSO 类型为 SAML
docker exec -u www-data nextcloud_app php occ config:app:set user_saml type --value="saml"

# 允许多后端（SAML + 本地密码同时生效）
docker exec -u www-data nextcloud_app php occ config:app:set user_saml general-allow_multiple_user_back_ends --value="1"

# 要求用户必须预配置（关闭自动创建账号）
docker exec -u www-data nextcloud_app php occ config:app:set user_saml general-require_provisioned_account --value="0"
```

> **提示**：设置 `general-require_provisioned_account=0` 时，SAML 认证成功后会自动创建 Nextcloud 用户。设为 `1` 则要求管理员预先创建用户。

### 可选安全加固

```bash
# 签名 AuthnRequest
docker exec -u www-data nextcloud_app php occ saml:config:set --security-authnRequestsSigned="1" 1

# 要求 Assertion 签名
docker exec -u www-data nextcloud_app php occ saml:config:set --security-wantAssertionsSigned="1" 1

# 要求消息签名
docker exec -u www-data nextcloud_app php occ saml:config:set --security-wantMessagesSigned="1" 1
```

### SAML 故障排查

```bash
# 检查 SAML 应用状态
docker exec -u www-data nextcloud_app php occ app:list | grep user_saml

# 查看 SAML 相关日志
docker exec nextcloud_app grep -i saml /var/www/html/data/nextcloud.log | tail -20

# 验证 SP metadata 可访问
curl -k https://nextcloud.newegg.org/apps/user_saml/saml/metadata

# 直接访问本地密码登录（SSO 故障时备用）
# https://nextcloud.newegg.org/login?direct=1
```

| 常见问题 | 原因 | 解决 |
|----------|------|------|
| 登录后跳转回登录页 | trusted_domains 未包含域名 | 检查 `config.php` 的 `trusted_domains` |
| SAML Response 验证失败 | 证书不匹配或过期 | 重新下载 Azure 证书并更新 `idp-x509cert` |
| 用户创建失败 | UID mapping 为空 | 确认 Azure 声明中包含对应属性 |
| `404 /apps/user_saml/saml/acs` | 应用未启用 | `php occ app:enable user_saml` |

## 数据持久化

| 路径 | 类型 | 内容 |
|------|------|------|
| `db_data` | Docker volume | MariaDB 数据文件 |
| `nextcloud_data` | Docker volume | Nextcloud 核心文件 |
| `/nextcloud-data` | 宿主机 bind mount | 用户上传的文件数据 |
| `./config` | 宿主机 bind mount | PHP 配置（Git 管理） |
| `./custom_apps` | 宿主机 bind mount | 第三方应用（Git 管理） |

## 运维操作

### 常用 occ 命令

```bash
# 进入容器执行 occ
alias occ='docker exec -u www-data nextcloud_app php occ'

# 扫描文件变更
occ files:scan --all

# 维护模式
occ maintenance:mode --on
occ maintenance:mode --off

# 数据库索引优化
occ db:add-missing-indices
occ db:add-missing-columns

# 升级
occ upgrade

# 状态检查
occ status
```

### 备份

```bash
# 1. 进入维护模式
docker exec -u www-data nextcloud_app php occ maintenance:mode --on

# 2. 备份数据库
docker exec nextcloud_db mysqldump -u root -p'<ROOT_PASSWORD>' nextcloud > backup_$(date +%F).sql

# 3. 备份用户数据
tar -czf nextcloud-data_$(date +%F).tar.gz /nextcloud-data

# 4. 退出维护模式
docker exec -u www-data nextcloud_app php occ maintenance:mode --off
```

### 升级 Nextcloud

```bash
# 1. 拉取新镜像
docker compose pull app cron

# 2. 滚动更新
docker compose up -d app cron

# 3. 执行数据库迁移
docker exec -u www-data nextcloud_app php occ upgrade
docker exec -u www-data nextcloud_app php occ db:add-missing-indices
```

## 安全事项

> [!CAUTION]
> `docker-compose.yaml` 和 `config/config.php` 中包含数据库密码和管理员密码的占位值。
> **部署前必须修改为强密码，且不要将真实密码提交到 Git。**

建议：
- 使用 `.env` 文件 + `env_file:` 指令管理敏感信息
- 将 `.env` 加入 `.gitignore`
- `config.php` 中的 `passwordsalt`、`secret`、`instanceid` 在首次安装后自动生成，**不要手动修改**

## 故障排查

```bash
# 查看应用日志
docker compose logs -f app

# 查看 Nextcloud 内部日志
docker exec nextcloud_app cat /var/www/html/data/nextcloud.log | tail -50

# 检查数据库连接
docker exec nextcloud_db mysql -u nextcloud -p'<PASSWORD>' -e "SELECT 1"

# 检查 Redis 连接
docker exec nextcloud_redis redis-cli ping

# 解决文件权限问题
docker exec nextcloud_app chown -R www-data:www-data /var/www/html/data
```

## 目录结构

```
nextcloud/
├── docker-compose.yaml          # 服务编排
├── README.md
├── config/                      # Nextcloud PHP 配置片段
│   ├── config.php               # 主配置（自动生成 + 运维维护）
│   ├── redis.config.php         # Redis 缓存配置
│   ├── s3.config.php            # S3 对象存储配置
│   ├── smtp.config.php          # SMTP 邮件配置
│   ├── reverse-proxy.config.php # 反向代理 / LB 适配
│   ├── apache-pretty-urls.config.php
│   ├── apcu.config.php
│   ├── apps.config.php
│   └── ...
└── custom_apps/                 # 第三方应用
    └── user_saml/               # SAML SSO 插件
```
