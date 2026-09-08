#!/usr/bin/env bash
# Shared shell environment for the Fedibird/Mastodon Cloud Agent setup.
# Sourced by install.sh, start-services.sh, and each terminal command.
#
# It puts the project's pinned toolchains ahead of anything else on PATH:
#   - Ruby 3.2.8 via rbenv (builds against the system OpenSSL 3)
#   - Node.js 20 via nvm (streaming needs jsdom 25 / Node >= 18; webpack 4 runs
#     with NODE_OPTIONS=--openssl-legacy-provider, set in the webpack command)
#
# nvm.sh and `rbenv init` are not safe under `set -u`/`set -e`, so we relax
# those options while loading them and restore the caller's settings after.

MASTODON_NODE_VERSION="20.20.2"

__mastodon_saved_opts="$(set +o)"
set +eu

# rbenv (Ruby 3.2.8)
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
if command -v rbenv >/dev/null 2>&1; then
  eval "$(rbenv init - bash)"
fi

# Node 20 via nvm. Prepend explicitly because the base image places another
# Node build early on PATH.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
NODE_BIN="$NVM_DIR/versions/node/v${MASTODON_NODE_VERSION}/bin"
if [ -d "$NODE_BIN" ]; then
  export PATH="$NODE_BIN:$PATH"
fi

# Restore the caller's shell options.
eval "$__mastodon_saved_opts"
unset __mastodon_saved_opts

export RAILS_ENV="${RAILS_ENV:-development}"
