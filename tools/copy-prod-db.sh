#!/usr/bin/env bash
#
# copy-prod-db.sh — Copy the Ghostfolio data from the external source (LXC) into
# the local dev stack (the gf-postgres-dev / gf-redis-dev containers started by
# docker/docker-compose.dev.yml).
#
# It copies both:
#   * PostgreSQL — pg_dump the source, then pg_restore into local (full replica).
#   * Redis      — SCAN + DUMP each key on the source, RESTORE into local
#                  (preserving TTLs). The read-only source ACL user cannot run
#                  SYNC/--rdb, so we copy key-by-key.
#
# No local psql/redis client is required — everything runs inside throwaway
# postgres:17-alpine / redis:alpine containers on the host network.
#
# Connection details are read from ../.env. Required variables there:
#   EXT_POSTGRES_DB, EXT_POSTGRES_RO_USER, EXT_POSTGRES_RO_PASSWORD
#   EXT_REDIS_RO_USER, EXT_REDIS_RO_PASSWORD
#   POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD   (local target)
#   REDIS_PASSWORD                                  (local target)
# Optional overrides (env or .env): EXT_HOST, EXT_POSTGRES_PORT, EXT_REDIS_PORT.
#
# Usage:
#   tools/copy-prod-db.sh              # copy postgres + redis (confirm first)
#   FORCE=1 tools/copy-prod-db.sh      # skip the confirmation prompt
#   DUMP_ONLY=1 tools/copy-prod-db.sh  # only write the pg dump file, no restore
#   SKIP_REDIS=1 tools/copy-prod-db.sh # postgres only
#   SKIP_POSTGRES=1 tools/copy-prod-db.sh # redis only
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Load configuration from .env -------------------------------------------
if [[ ! -f "$REPO_DIR/.env" ]]; then
  echo "ERROR: $REPO_DIR/.env not found." >&2
  exit 1
fi
# shellcheck disable=SC1091
set -a; source "$REPO_DIR/.env"; set +a

require() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: required variable '$name' is not set in .env" >&2
    exit 1
  fi
}

# --- Source (external / LXC) ------------------------------------------------
EXT_HOST="${EXT_HOST:-192.168.1.221}"
EXT_POSTGRES_PORT="${EXT_POSTGRES_PORT:-5432}"
EXT_REDIS_PORT="${EXT_REDIS_PORT:-6379}"
require EXT_POSTGRES_DB
require EXT_POSTGRES_RO_USER
require EXT_POSTGRES_RO_PASSWORD
require EXT_REDIS_RO_USER
require EXT_REDIS_RO_PASSWORD

# --- Target (local dev) -----------------------------------------------------
# The dev compose publishes Postgres/Redis on the host, so from inside a
# --network host container "localhost" reaches them.
DST_HOST="${DST_HOST:-localhost}"
DST_POSTGRES_PORT="${DST_POSTGRES_PORT:-5432}"
DST_REDIS_PORT="${DST_REDIS_PORT:-6379}"
require POSTGRES_DB
require POSTGRES_USER
require POSTGRES_PASSWORD
require REDIS_PASSWORD

PG_IMAGE="${PG_IMAGE:-postgres:17-alpine}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:alpine}"
DUMP_DIR="${DUMP_DIR:-/tmp}"
DUMP_FILE="${DUMP_FILE:-$DUMP_DIR/ghostfolio-src.dump}"

echo "==> Postgres source: ${EXT_POSTGRES_RO_USER}@${EXT_HOST}:${EXT_POSTGRES_PORT}/${EXT_POSTGRES_DB}"
echo "==> Postgres target: ${POSTGRES_USER}@${DST_HOST}:${DST_POSTGRES_PORT}/${POSTGRES_DB}"
echo "==> Redis source:    ${EXT_REDIS_RO_USER}@${EXT_HOST}:${EXT_REDIS_PORT}"
echo "==> Redis target:    ${DST_HOST}:${DST_REDIS_PORT}"

# --- Confirm ----------------------------------------------------------------
if [[ "${FORCE:-0}" != "1" && "${DUMP_ONLY:-0}" != "1" ]]; then
  echo
  echo "!!  This OVERWRITES the local database '${POSTGRES_DB}' and flushes the"
  echo "    local Redis cache, replacing them with source data."
  read -r -p "    Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

# ============================================================================
# PostgreSQL
# ============================================================================
copy_postgres() {
  echo
  echo "### PostgreSQL ###"
  echo "==> Checking connectivity..."
  docker run --rm --network host -e PGPASSWORD="$EXT_POSTGRES_RO_PASSWORD" "$PG_IMAGE" \
    psql -h "$EXT_HOST" -p "$EXT_POSTGRES_PORT" -U "$EXT_POSTGRES_RO_USER" -d "$EXT_POSTGRES_DB" \
    -tAc "select 'source ok, '||count(*)||' tables' from information_schema.tables where table_schema='public';"
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_IMAGE" \
    psql -h "$DST_HOST" -p "$DST_POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select 'target ok'"

  # Custom format (-Fc): compressed, restorable with pg_restore + --clean.
  echo "==> Dumping source -> ${DUMP_FILE}"
  docker run --rm --network host -e PGPASSWORD="$EXT_POSTGRES_RO_PASSWORD" -v "$DUMP_DIR:$DUMP_DIR" "$PG_IMAGE" \
    pg_dump -h "$EXT_HOST" -p "$EXT_POSTGRES_PORT" -U "$EXT_POSTGRES_RO_USER" -d "$EXT_POSTGRES_DB" \
    --format=custom --no-owner --no-privileges --file "$DUMP_FILE"
  echo "==> Dump complete ($(du -h "$DUMP_FILE" | cut -f1))"

  if [[ "${DUMP_ONLY:-0}" == "1" ]]; then
    echo "==> DUMP_ONLY set; not restoring. File at $DUMP_FILE"
    return 0
  fi

  # --clean --if-exists drops each object before recreating it, so the restore
  # is idempotent and yields an exact replica (incl. _prisma_migrations).
  echo "==> Restoring into ${POSTGRES_DB}..."
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" -v "$DUMP_DIR:$DUMP_DIR" "$PG_IMAGE" \
    pg_restore -h "$DST_HOST" -p "$DST_POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --clean --if-exists --no-owner --no-privileges --exit-on-error "$DUMP_FILE"

  echo "==> Restore complete. Row counts:"
  docker run --rm --network host -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_IMAGE" \
    psql -h "$DST_HOST" -p "$DST_POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -c \
    "select table_name||'='||(xpath('/row/c/text()', query_to_xml(format('select count(*) c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
     from information_schema.tables where table_schema='public' order by table_name;"
}

# ============================================================================
# Redis
# ============================================================================
# The read-only source ACL user cannot SYNC/--rdb, so copy key-by-key:
# SCAN -> DUMP (+PTTL) on the source, RESTORE on the target. Runs inside one
# container so source and target redis-cli share a shell.
#
# Binary-safety note: `redis-cli DUMP` writes the raw serialization followed by a
# single trailing newline. That extra byte makes RESTORE fail with
# "DUMP payload version or checksum are wrong", so we strip it with `head -c -1`
# and feed the exact bytes to RESTORE via `-x` (reads the trailing value arg
# from stdin). One temp file per key keeps the payload off the argv/pipe text path.
copy_redis() {
  echo
  echo "### Redis ###"
  docker run --rm --network host \
    -e SRC_HOST="$EXT_HOST" -e SRC_PORT="$EXT_REDIS_PORT" \
    -e SRC_USER="$EXT_REDIS_RO_USER" -e SRC_PASS="$EXT_REDIS_RO_PASSWORD" \
    -e DST_HOST="$DST_HOST" -e DST_PORT="$DST_REDIS_PORT" -e DST_PASS="$REDIS_PASSWORD" \
    "$REDIS_IMAGE" sh -c '
      set -e
      SRC="redis-cli -h $SRC_HOST -p $SRC_PORT --user $SRC_USER --pass $SRC_PASS --no-auth-warning"
      DST="redis-cli -h $DST_HOST -p $DST_PORT --pass $DST_PASS --no-auth-warning"

      echo "==> Source has $($SRC DBSIZE) keys; target has $($DST DBSIZE) keys."
      echo "==> Flushing target Redis..."
      $DST FLUSHDB >/dev/null

      n=0; skipped=0
      $SRC --scan | while IFS= read -r key; do
        [ -z "$key" ] && continue
        ttl=$($SRC PTTL "$key"); [ "$ttl" -lt 0 ] && ttl=0
        # Strip redis-cli'\''s trailing newline so the payload checksum stays valid.
        $SRC DUMP "$key" | head -c -1 > /tmp/gf-redis-key.bin
        if [ ! -s /tmp/gf-redis-key.bin ]; then skipped=$((skipped+1)); continue; fi
        $DST DEL "$key" >/dev/null
        if $DST -x RESTORE "$key" "$ttl" < /tmp/gf-redis-key.bin >/dev/null 2>&1; then
          n=$((n+1))
        else
          echo "    ! failed to restore key: $key" >&2
          skipped=$((skipped+1))
        fi
      done
      rm -f /tmp/gf-redis-key.bin
      echo "==> Copied keys; target now has $($DST DBSIZE) keys."
    '
}

[[ "${SKIP_POSTGRES:-0}" == "1" ]] || copy_postgres
[[ "${SKIP_REDIS:-0}" == "1" ]] || copy_redis

echo
echo "==> Done. Restart the API server if it was running so it picks up the new data."
