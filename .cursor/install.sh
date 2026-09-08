#!/usr/bin/env bash
# Idempotent repository bootstrap for the Fedibird/Mastodon Cloud Agent.
# Runs after the source tree is checked out. Toolchains (Ruby 3.2.8, Node 20,
# system packages, PostgreSQL, Redis) are already baked into the base snapshot;
# this script only refreshes source-derived state.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/.cursor/mastodon-env.sh"

BUNDLER_VERSION="2.6.9"

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
RAILS_ENV=development
DB_HOST=localhost
DB_PORT=5432
DB_USER=mastodon
DB_PASS=mastodon
DB_NAME=mastodon_development
REDIS_HOST=localhost
REDIS_PORT=6379
ES_ENABLED=false
STREAMING_CLUSTER_NUM=1
ENVEOF
fi

# 2. Ruby dependencies (installed into the persistent rbenv global gem path).
echo "[install] Installing Ruby gems (bundle install)..."
gem list -i bundler -v "$BUNDLER_VERSION" >/dev/null 2>&1 || gem install bundler -v "$BUNDLER_VERSION"
bundle "_${BUNDLER_VERSION}_" install --jobs "$(nproc)"

# 3. JavaScript dependencies. Node 20 satisfies package.json engines (>=20) and
#    the streaming server's jsdom 25; --ignore-engines is kept defensively for
#    any transitively stricter engine constraints.
echo "[install] Installing JS dependencies (yarn install)..."
yarn install --frozen-lockfile --ignore-engines

# 4. Database: start services, then create/load schema + migrate idempotently.
echo "[install] Ensuring PostgreSQL and Redis are up..."
bash "$REPO_ROOT/.cursor/start-services.sh"

echo "[install] Preparing database (create + load schema if needed, then migrate)..."
# NB: we avoid `db:prepare`/`db:setup` because their seed step builds an admin
# whose email is admin@$LOCAL_DOMAIN, which fails validation when LOCAL_DOMAIN
# has a port. Load the schema explicitly, then migrate (both idempotent).
if ! bundle "_${BUNDLER_VERSION}_" exec rails db:version >/dev/null 2>&1; then
  bundle "_${BUNDLER_VERSION}_" exec rails db:create
  bundle "_${BUNDLER_VERSION}_" exec rails db:schema:load
fi
bundle "_${BUNDLER_VERSION}_" exec rails db:migrate

# 5. Development admin account (idempotent). Uses a port-free, valid email so it
#    passes validation; log in at http://localhost:3000 with admin@localhost.
echo "[install] Ensuring development admin account exists..."
bundle "_${BUNDLER_VERSION}_" exec rails runner "$REPO_ROOT/.cursor/dev_admin.rb"

echo "[install] Done."
