# Nextcloud

部署服务器 : 172.16.160.231 e11ncloud01
访问地址 : http://test.neweggbox.com（宿主机 **80** 端口映射到容器 HTTP）

基于 Docker Compose 的 Nextcloud 企业级私有云部署方案，面向 Newegg 内网环境。
身份认证使用 Nextcloud 自带登录（可按需安装其他认证应用）；出站邮件未在仓库内预置，可在管理后台自行配置。

---

## 目录

1. [架构概览](#架构概览)
2. [前置条件](#前置条件)
3. [快速部署](#快速部署)
4. [配置说明](#配置说明)
5. [员工离职处理流程](#员工离职处理流程)
6. [数据持久化](#数据持久化)
7. [运维操作](#运维操作)
8. [故障排查](#故障排查)
9. [安全事项与待办](#安全事项与待办)
10. [目录结构](#目录结构)

---

## 架构概览

```
  浏览器 / 客户端  ──HTTP:80──►  宿主机 :80  ──►  nextcloud_app :80
                                      │
                    ┌─────────────────┴─────────────────┐
                    │       Docker (nextcloud_net)       │
          ┌─────────┴─────────┐                         │
          │   nextcloud_app   │◄── cron 容器           │
          │   (Nextcloud 33)  │    (定时任务)          │
          └──┬──────┬─────────┘                         │
             │      │                                  │
      ┌──────┘      └──────┐                           │
      ▼                    ▼                           │
┌───────────┐      ┌──────────────┐                    │
│  MariaDB  │      │    Redis     │                    │
│  10.11    │      │  7 (Alpine)  │                    │
└───────────┘      └──────────────┘                    │
└──────────────────────────────────────────────────────┘
```

| 服务 | 镜像 | 端口 | 用途 |
|------|------|------|------|
| `app` | `nextcloud:latest` (33.0.2.2) | `80:80` | Nextcloud 主服务（HTTP） |
| `db` | `mariadb:10.11` | internal | 数据库（binlog + ROW 格式） |
| `redis` | `redis:7-alpine` | internal | 分布式缓存 & 文件锁 |
| `cron` | `nextcloud:latest` | — | 后台定时任务（`/cron.sh`） |

> 所有镜像统一从内部 Registry `a.newegg.org/newegg-docker/` 拉取。

---

## 前置条件

- Docker Engine ≥ 20.10，Docker Compose ≥ 1.29（或 `docker compose` v2）
- 宿主机预创建目录：`/nextcloud-data`（用户数据挂载点）
- **无前置负载均衡**：用户直连宿主机 **TCP 80**（`docker-compose` 中 `ports: "80:80"`）。Windows 上绑定 80 端口可能需要管理员权限或避免与其它服务冲突。
- DNS（可选）：将 `test.neweggbox.com` 解析到本机 IP；若仅用 IP 访问，需在 Nextcloud `trusted_domains` 中加入该 IP。

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

首次启动约需 1-2 分钟完成数据库初始化和应用安装。访问 `http://test.neweggbox.com` 或 `http://<服务器IP>` 验证。

---

## 配置说明

配置文件采用 Nextcloud 的分片加载机制，`config/` 下每个 `.config.php` 独立管理一个功能模块。核心 `config.php` 由 Nextcloud 管理（`instanceid`、`passwordsalt`、`secret` 自动生成，**不要手动改**）。

当前生效的关键参数（`config/config.php`）：

```php
'overwritehost'      => 'test.neweggbox.com',
'overwriteprotocol'  => 'http',
'trusted_domains'    => ['localhost', 'test.neweggbox.com'],
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
NEXTCLOUD_TRUSTED_DOMAINS: test.neweggbox.com
OVERWRITEPROTOCOL: http
OVERWRITEHOST: test.neweggbox.com
OVERWRITECLIURL: http://test.neweggbox.com
PHP_MEMORY_LIMIT: 512M
PHP_UPLOAD_LIMIT: 10G
```

---

## 员工离职处理流程

### 整体流程

```
员工离职
  │
  └─ bash offboard-user.sh（按需带继任者邮箱做文件交接）
          ├─ files:transfer-ownership → 文件交接（可选）
          ├─ user:disable → 封禁登录
          └─ 30-90 天保留期后 → user:delete 彻底删除

  同时在企业统一账号 / 权限系统中按流程撤销该用户对相关系统的访问。
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
4. **控制台摘要** — 输出数据大小、交接状态；运维可按需自行通知相关方

### 彻底删除（保留期结束后）

```bash
OCC='docker exec -u www-data nextcloud_app php occ'

# 删除用户（连同所有数据）
$OCC user:delete leaver@newegg.com
```

> [!CAUTION]
> `user:delete` 会永久删除该用户的所有文件、共享和设置，且**不可逆**。请确认已过数据保留期。

---

## 数据持久化

### Volumes 总览

| 宿主机路径 | 容器内路径 | 类型 | 说明 | 需备份 |
|------------|-----------|------|------|--------|
| `db_data` (named) | `/var/lib/mysql` | Docker volume | MariaDB 数据文件（所有表、索引、binlog） | ✅ 用 `mysqldump` |
| `nextcloud_data` (named) | `/var/www/html` | Docker volume | Nextcloud PHP 程序文件、内置应用 | ❌ 镜像自带，升级会重建 |
| `/nextcloud-data` | `/var/www/html/data` | Bind mount | **用户上传的所有文件**，按 `data/<uid>/files/` 存储；也包含 `nextcloud.log` | ✅ 最重要 |
| `./config` | `/var/www/html/config` | Bind mount | PHP 配置片段（`config.php` + 各模块 `.config.php`），Git 管理 | ✅ Git 已跟踪 |
| `./custom_apps` | `/var/www/html/custom_apps` | Bind mount | 可选：手动安装的第三方应用目录 | ✅ Git 已跟踪 |

> `app` 和 `cron` 两个容器共享完全相同的 volume 挂载，确保 cron 任务能访问同一份数据和配置。

### 用户文件存储结构

```
/nextcloud-data/                        # 宿主机
├── admin/
│   └── files/                          # admin 用户的文件
│       ├── Documents/
│       └── Photos/
├── Suntek.Q.Ma@newegg.com/
│   └── files/                          # 典型用户目录（uid 常为邮箱）
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

# （按需配置邮件等功能见官方文档或 Web 管理界面）
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

> [!WARNING]
> Nextcloud **绝对不支持跨主版本升级**（例如：不允许 31 → 33，必须 31 → 32 → 33）。
> 如果你在 `docker-compose.yaml` 中使用的是 `nextcloud:latest` 标签，极长时间不更新后再次 `pull` 拉取镜像，可能会因为跨了多个主版本导致启动报错！
> 为了安全，在生产环境中强烈建议将 `latest` 替换为具体的版本号（如 `nextcloud:33`），并且每次升级时手动递增主版本号。

**标准 Docker 部署版的升级规范流程**：

1. **备份（必须！）**：包括数据库和用户数据（见上文「备份」章节）。
2. **下载最新镜像**：
   ```bash
   docker compose pull app cron
   ```
3. **重建容器以应用新镜像**：
   ```bash
   docker compose up -d app cron
   ```
   *(Nextcloud 的官方 Docker 镜像入口脚本会自动检测到版本号变更，并在容器启动时触发内部预处理及 `occ upgrade`)*
4. **通过日志确认升级状态**：
   ```bash
   docker compose logs -f app
   ```
   等待日志提示升级成功并没有报错。
5. **升级后数据库收尾优化（重要）**：
   每次大版本升级后，通常需要建立新索引和转换部分数据类型以保证性能。请依次执行：
   ```bash
   OCC='docker exec -u www-data nextcloud_app php occ'
   $OCC db:add-missing-indices
   $OCC db:add-missing-columns
   $OCC db:convert-filecache-bigint
   ```
6. **取消维护模式**：
   如果在升级过程中卡在维护模式，或者你需要提早恢复服务，请执行：
   ```bash
   $OCC maintenance:mode --off
   ```

---

## 故障排查

```bash
# 容器日志
docker compose logs -f app

# Nextcloud 内部日志
docker exec nextcloud_app tail -200 /var/www/html/data/nextcloud.log

# 实时跟日志（可按关键字筛选）
docker exec nextcloud_app tail -f /var/www/html/data/nextcloud.log \
  | grep -iE 'error|critical'

# 数据库连接
docker exec nextcloud_db mysql -u nextcloud -p'<PASSWORD>' -e 'SELECT 1'

# Redis 连接
docker exec nextcloud_redis redis-cli ping

# 修文件权限
docker exec nextcloud_app chown -R www-data:www-data /var/www/html/data
```

若启动日志出现 **`rsync` … `EmptyContentSecurityPolicy.php` … `Device or resource busy`**：说明曾把 **core 源码文件** bind-mount 到 `/var/www/html/...`。官方镜像会把程序同步到 `nextcloud_data` 卷，与挂载点冲突。**不要**在 `docker-compose` 里覆盖 `lib/` 下文件；CSP 等请用管理后台或 `config` 支持的方式配置。

### `Cannot write into "config" directory!`

`./config` 挂载到容器内 `/var/www/html/config` 时，**www-data（uid 33）必须可写该目录**，否则首次安装会报错。

**Linux 宿主机：**

```bash
sudo chown -R 33:33 ./config
sudo chmod -R u+rwX ./config
```

改完后重启：`docker compose restart app`（或 `up -d`）。

**Docker Desktop（Windows / Mac）：** 尽量把工程放在 **WSL2 的 Linux 路径**（如 `\\wsl$\Ubuntu\home\...`）再运行 Compose，避免在 `C:\` 的目录挂载上常出现的权限/只读问题。若仍失败，可在 WSL 里进入项目目录执行上面的 `chown`/`chmod`（仅当该路径在 WSL 文件系统内）。

**确认是否已装上：** `docker exec -u www-data nextcloud_app php occ status`

### `FATAL: Could not open the config file .../reverse-proxy.config.php`

说明当前挂载的 **`config/` 里缺少该文件**，或 **Web 用户无法读取**（权限/只读卷）。

1. 宿主机检查：`ls -la config/reverse-proxy.config.php`（须存在且可读）。
2. 若缺少：在项目根执行 `git pull`，或从镜像拷出后再赋权：
   ```bash
   docker compose run --rm --no-deps --entrypoint cat app \
     /usr/src/nextcloud/config/reverse-proxy.config.php > config/reverse-proxy.config.php
   sudo chown 33:33 config/reverse-proxy.config.php
   chmod u+r config/reverse-proxy.config.php
   ```
3. 确认整条 **`./config` 目录**对 uid **33** 可读（见上一节 `chown`）。

镜像若提示 `reverse-proxy.config.php` / `smtp.config.php` 与镜像内副本不一致：本仓库已尽量与官方 `nextcloud/docker` 的 `.config` 片段对齐；你已自定义 `config.php` 时仍可能提示，一般可忽略。

---

## 安全事项与待办

### 部署期强制项

> [!CAUTION]
> `docker-compose.yaml` 和 `config/config.php` 中包含数据库密码等占位值。
> **部署前必须改为强密码，真实凭据不要进 Git。**

- 用 `.env` + `env_file:` 管理敏感信息，`.env` 加入 `.gitignore`
- `config.php` 的 `passwordsalt` / `secret` / `instanceid` 首次安装自动生成，**不要手改**

### 待办清单

| 优先级 | 项 | 说明 |
|--------|-----|------|

---

## 目录结构

```
nextcloud/
├── docker-compose.yaml          # 服务编排
├── README.md                    # 本文件
├── setup-cron.sh                # 将 offboard-user.sh 部署到 /opt/nextcloud，并清理宿主机 crontab 中的旧版同步条目
├── offboard-user.sh             # 员工离职处理（disable + 文件交接 + 控制台摘要）
├── config/                      # Nextcloud PHP 配置片段
│   ├── config.php               # 主配置（Nextcloud 管理 + 运维维护）
│   ├── redis.config.php
│   ├── s3.config.php
│   ├── reverse-proxy.config.php
│   ├── apache-pretty-urls.config.php
│   ├── apcu.config.php
│   └── apps.config.php
├── custom_apps/                 # 可选：第三方应用（当前可为空，保留挂载目录）
└── data/                        # 运行时 - nextcloud.log 等（bind）
```
