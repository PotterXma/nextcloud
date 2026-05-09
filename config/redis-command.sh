#!/bin/sh
# Nextcloud：分布式缓存 / 锁 / PHP 会话。持久化关闭为刻意取舍。
# 内存上限可通过环境变量 REDIS_MAXMEMORY 覆盖（默认 256mb），见 .env.example。
set -eu

MAXMEMORY="${REDIS_MAXMEMORY:-256mb}"

if [ -n "${REDIS_HOST_PASSWORD:-}" ]; then
  exec redis-server \
    --maxmemory "$MAXMEMORY" \
    --maxmemory-policy allkeys-lru \
    --save "" \
    --appendonly no \
    --tcp-keepalive 60 \
    --lazyfree-lazy-eviction yes \
    --lazyfree-lazy-expire yes \
    --requirepass "$REDIS_HOST_PASSWORD"
else
  exec redis-server \
    --maxmemory "$MAXMEMORY" \
    --maxmemory-policy allkeys-lru \
    --save "" \
    --appendonly no \
    --tcp-keepalive 60 \
    --lazyfree-lazy-eviction yes \
    --lazyfree-lazy-expire yes
fi
