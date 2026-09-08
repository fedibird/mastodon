#!/usr/bin/env bash
# Idempotent repository bootstrap for the Fedibird/Mastodon Cloud Agent.
# Runs after the source tree is checked out. Toolchains (Ruby 2.7.4, Node 14,
# OpenSSL 1.1, system packages, PostgreSQL, Redis) are already baked into the
# base snapshot; this script only refreshes source-derived state.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/.cursor/mastodon-env.sh"

echo "[install] Ruby: $(ruby -v)"
echo "[install] Node: $(node -v)"
echo "[install] Yarn: $(yarn -v)"

# 1. Development .env (gitignored). Create with sensible local defaults if absent.
if [ ! -f "$REPO_ROOT/.env" ]; then
  echo "[install] Writing development .env ..."
  cat > "$REPO_ROOT/.env" <<'ENVEOF'
# Development environment configuration for Cloud Agent
LOCAL_DOMAIN=localhost:3000
LOCAL_HTTPS=false
REDIS_HOST=localhost
REDIS_PORT=6379
DB_HOST=localhost
DB_USER=mastodon
DB_NAME=mastodon_development
DB_PASS=mastodon
DB_PORT=5432
ES_ENABLED=false
ENVEOF
fi

# 2. Ruby dependencies (installed into the persistent rbenv global gem path).
echo "[install] Installing Ruby gems (bundle install)..."
gem list -i bundler -v 2.4.22 >/dev/null 2>&1 || gem install bundler -v 2.4.22
bundle _2.4.22_ install --jobs "$(nproc)"

# 3. JavaScript dependencies.
echo "[install] Installing JS dependencies (yarn install)..."
yarn install --frozen-lockfile

# 4. Database: start services, then create/migrate idempotently.
echo "[install] Ensuring PostgreSQL and Redis are up..."
bash "$REPO_ROOT/.cursor/start-services.sh"

echo "[install] Preparing database (create if needed + migrate)..."
# db:prepare creates and loads the schema if the DB is missing, otherwise migrates.
bundle _2.4.22_ exec rails db:prepare

echo "[install] Done."
