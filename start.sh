#!/usr/bin/env bash
# GitBucket start script for Railway.
#  1. wait for PostgreSQL (from the PG* reference variables),
#  2. on a new database, build the schema on loopback and replace the built-in
#     root/root password with ADMIN_PASSWORD before the public port opens,
#  3. size the JVM for small plans and exit non-zero on OutOfMemoryError,
#  4. enable git over SSH when the service has a Railway TCP proxy.
set -euo pipefail
log() { echo "[gitbucket-railway] $*"; }
die() { echo "[gitbucket-railway] FATAL: $*" >&2; exit 1; }

export GITBUCKET_HOME="${GITBUCKET_HOME:-/gitbucket}"
mkdir -p "$GITBUCKET_HOME"
DEFAULT_ROOT_SHA1="dc76e9f0c0006e8f919e0c515c66dbba3982f785"   # sha1("root"), set by GitBucket's first migration

# ---- JVM: heap as a share of the container limit, small stacks, exit on OOM
JAVA_OPTS="-XX:+UseSerialGC -XX:MaxRAMPercentage=${GITBUCKET_HEAP_PERCENT:-45} -XX:ReservedCodeCacheSize=64m -Xss512k -XX:+ExitOnOutOfMemoryError -Djava.net.preferIPv6Addresses=true ${JAVA_OPTS:-}"

# ---- database
: "${PGHOST:?PGHOST is not set (reference \${{Postgres.PGHOST}})}"
: "${PGUSER:?PGUSER is not set (reference \${{Postgres.PGUSER}})}"
: "${PGPASSWORD:?PGPASSWORD is not set (reference \${{Postgres.PGPASSWORD}})}"
export PGPORT="${PGPORT:-5432}" PGDATABASE="${PGDATABASE:-railway}" PGCONNECT_TIMEOUT=5
export GITBUCKET_DB_URL="jdbc:postgresql://${PGHOST}:${PGPORT}/${PGDATABASE}"
export GITBUCKET_DB_USER="$PGUSER" GITBUCKET_DB_PASSWORD="$PGPASSWORD"
export GITBUCKET_DB_MAXIMUMPOOLSIZE="${GITBUCKET_DB_MAXIMUMPOOLSIZE:-5}"

for i in $(seq 1 60); do
  pg_isready -q && break
  [ "$i" = 60 ] && die "PostgreSQL at ${PGHOST}:${PGPORT} is not ready after 5 minutes"
  log "waiting for PostgreSQL (${i}/60)"; sleep 5
done
log "PostgreSQL is ready"
psql_q() { psql -qtAX -v ON_ERROR_STOP=1 -c "$1"; }

# ---- base URL (needed for SSH clone URLs, webhooks and mails)
if [ -z "${GITBUCKET_BASE_URL:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  export GITBUCKET_BASE_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi

# ---- first boot: build the schema on loopback, then replace root/root.
# A PostgreSQL advisory lock (held by a background psql) keeps two overlapping
# deploys from migrating the same new database at once.
LOCKDIR="$(mktemp -d)"; mkfifo "$LOCKDIR/in"
psql -qtAX -v ON_ERROR_STOP=1 <"$LOCKDIR/in" >"$LOCKDIR/out" 2>&1 &
LOCK_PID=$!
exec 3>"$LOCKDIR/in"
echo "SELECT pg_advisory_lock(294180); SELECT 'locked';" >&3
for i in $(seq 1 600); do
  grep -q '^locked$' "$LOCKDIR/out" 2>/dev/null && break
  kill -0 "$LOCK_PID" 2>/dev/null || die "could not take the first-boot lock: $(cat "$LOCKDIR/out")"
  [ "$i" = 600 ] && die "timed out waiting for the first-boot lock"
  [ $((i % 30)) = 0 ] && log "waiting for another deploy to finish first boot"
  sleep 1
done
if [ "$(psql_q "SELECT to_regclass('public.account') IS NOT NULL")" != "t" ]; then
  log "new database: building the GitBucket schema on loopback (public port stays closed)"
  ( unset GITBUCKET_SSH GITBUCKET_SSH_BINDADDRESS_HOST GITBUCKET_SSH_BINDADDRESS_PORT GITBUCKET_SSH_PUBLICADDRESS_HOST GITBUCKET_SSH_PUBLICADDRESS_PORT
    exec java $JAVA_OPTS -jar /opt/gitbucket.war --host=127.0.0.1 --port=8099 ) &
  BOOT_PID=$!
  ok=0
  for i in $(seq 1 300); do
    if curl -fs -o /dev/null http://localhost:8099/signin; then ok=1; break; fi
    kill -0 "$BOOT_PID" 2>/dev/null || die "GitBucket exited while building the schema"
    sleep 1
  done
  kill "$BOOT_PID" 2>/dev/null || true; wait "$BOOT_PID" 2>/dev/null || true
  [ "$ok" = 1 ] || die "GitBucket did not finish building the schema in 5 minutes"
  [ "$(psql_q "SELECT to_regclass('public.account') IS NOT NULL")" = "t" ] || die "schema missing after the first boot"
fi
if [ "$(psql_q "SELECT count(*) FROM account WHERE user_name='root' AND password='${DEFAULT_ROOT_SHA1}'")" != "0" ]; then
  [ -n "${ADMIN_PASSWORD:-}" ] || die "ADMIN_PASSWORD must be set: root still has GitBucket's default password"
  HASH="$(printf '%s' "$ADMIN_PASSWORD" | sha1sum | cut -d' ' -f1)"
  psql_q "UPDATE account SET password='${HASH}' WHERE user_name='root' AND password='${DEFAULT_ROOT_SHA1}'" >/dev/null
  log "root password set from ADMIN_PASSWORD (GitBucket rehashes it with PBKDF2 at first sign-in)"
fi
exec 3>&-; wait "$LOCK_PID" 2>/dev/null || true; rm -r "$LOCKDIR"

# ---- git over SSH through a Railway TCP proxy (optional)
if [ -n "${RAILWAY_TCP_PROXY_DOMAIN:-}" ] && [ -n "${RAILWAY_TCP_PROXY_PORT:-}" ] && [ -n "${GITBUCKET_BASE_URL:-}" ]; then
  export GITBUCKET_SSH=true
  export GITBUCKET_SSH_BINDADDRESS_HOST="${GITBUCKET_SSH_BINDADDRESS_HOST:-0.0.0.0}"
  export GITBUCKET_SSH_BINDADDRESS_PORT="${RAILWAY_TCP_APPLICATION_PORT:-29418}"
  export GITBUCKET_SSH_PUBLICADDRESS_HOST="$RAILWAY_TCP_PROXY_DOMAIN"
  export GITBUCKET_SSH_PUBLICADDRESS_PORT="$RAILWAY_TCP_PROXY_PORT"
  log "SSH: ssh://git@${RAILWAY_TCP_PROXY_DOMAIN}:${RAILWAY_TCP_PROXY_PORT}/OWNER/REPO.git"
fi

log "starting GitBucket 4.48.0 on port ${PORT:-8080}"
java $JAVA_OPTS -jar /opt/gitbucket.war --host=0.0.0.0 --port="${PORT:-8080}" &
APP_PID=$!
STOPPING=0
trap 'STOPPING=1; kill -TERM "$APP_PID" 2>/dev/null' TERM INT

# Watchdog: Jetty keeps running (and answering 503) when the web app fails to
# start or later stops answering, so exit non-zero after 5 minutes without a
# healthy answer, and Railway's ON_FAILURE policy restarts the service.
( fails=0; up=0
  while kill -0 "$APP_PID" 2>/dev/null; do
    sleep 30
    if curl -fs -m 20 -o /dev/null "http://localhost:${PORT:-8080}/signin"; then up=1; fails=0
    else fails=$((fails + 1)); fi
    limit=10; [ "$up" = 0 ] && limit=20
    if [ "$fails" -ge "$limit" ]; then
      echo "[gitbucket-railway] FATAL: GitBucket has not answered for $((fails * 30)) s; exiting so Railway restarts it" >&2
      kill -KILL "$APP_PID" 2>/dev/null; exit 0
    fi
  done ) &
WATCH_PID=$!

set +e
wait "$APP_PID"; rc=$?
[ "$STOPPING" = 1 ] && { wait "$APP_PID" 2>/dev/null; rc=$?; }
kill "$WATCH_PID" 2>/dev/null
if [ "$STOPPING" = 1 ]; then log "stopped"; exit 0; fi
log "GitBucket exited unexpectedly (code $rc)"
[ "$rc" = 0 ] && rc=1
exit "$rc"
