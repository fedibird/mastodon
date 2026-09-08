#!/usr/bin/env bash
# Shared shell environment for the Fedibird/Mastodon Cloud Agent setup.
# Sourced by install.sh, start-services.sh, and each terminal command.
#
# It puts the project's pinned toolchains ahead of anything else on PATH:
#   - Ruby 2.7.4 via rbenv (built against OpenSSL 1.1 at /opt/openssl-1.1)
#   - Node.js 14 via nvm (required by webpack 4 / the streaming server)
#
# nvm.sh and `rbenv init` are not safe under `set -u`/`set -e`, so we relax
# those options while loading them and restore the caller's settings after.

MASTODON_NODE_VERSION="14.21.3"

__mastodon_saved_opts="$(set +o)"
set +eu

# rbenv (Ruby 2.7.4)
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# Node 14 via nvm. Prepend explicitly because the base image places another
# Node build early on PATH; webpack 4 breaks on Node >= 17 (OpenSSL 3).
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
NODE14_BIN="$NVM_DIR/versions/node/v${MASTODON_NODE_VERSION}/bin"
if [ -d "$NODE14_BIN" ]; then
  export PATH="$NODE14_BIN:$PATH"
fi

# Restore the caller's shell options.
eval "$__mastodon_saved_opts"
unset __mastodon_saved_opts

export RAILS_ENV="${RAILS_ENV:-development}"
