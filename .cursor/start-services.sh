#!/usr/bin/env bash
# Start (or reconcile) the infrastructure services Mastodon depends on:
# PostgreSQL and Redis. Idempotent and safe to run on every boot.
set -euo pipefail

echo "[start-services] Ensuring PostgreSQL is running..."
if ! sudo pg_isready -q; then
  # pg_ctlcluster is the Debian/Ubuntu wrapper; fall back to the service script.
  sudo pg_ctlcluster 16 main start 2>/dev/null || sudo service postgresql start || true
fi
# Wait for readiness.
for i in $(seq 1 30); do
  if sudo pg_isready -q; then break; fi
  sleep 1
done
sudo pg_isready && echo "[start-services] PostgreSQL is ready."

# Ensure the 'mastodon' role exists (persisted in the snapshot, but re-create if missing).
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='mastodon'" | grep -q 1; then
  echo "[start-services] Creating 'mastodon' PostgreSQL role..."
  sudo -u postgres psql -c "CREATE USER mastodon WITH PASSWORD 'mastodon' CREATEDB SUPERUSER;"
fi

echo "[start-services] Ensuring Redis is running..."
if ! redis-cli ping >/dev/null 2>&1; then
  sudo service redis-server start || true
fi
for i in $(seq 1 30); do
  if redis-cli ping >/dev/null 2>&1; then break; fi
  sleep 1
done
redis-cli ping >/dev/null 2>&1 && echo "[start-services] Redis is ready."

echo "[start-services] Done."
