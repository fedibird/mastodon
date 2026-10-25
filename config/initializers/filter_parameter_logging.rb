# frozen_string_literal: true

# Be sure to restart your server when you modify this file.

# Configure sensitive parameters which will be filtered from the log file.
#
# These are substring filters. :credential redacts any parameter whose name
# contains "credential" (including credential_payload and credential_type).
# :secret redacts client_secret and other *secret* parameter names. provider
# and purpose are not filtered; they are not secret.
Rails.application.config.filter_parameters += [
  :password,
  :private_key,
  :public_key,
  :otp_attempt,
  :credential,
  :credential_payload,
  :api_key,
  :access_token,
  :refresh_token,
  :client_secret,
  :secret,
  :encrypted_payload,
  :status_ids,
  :fallback_confirmation,
  :seek_target,
  # Exact names only. A bare :q or :text would redact every key that contains
  # those letters. Membership rejects search text; ids are not a search query
  # but they are still not useful in the log.
  /\A(?:q|query|text|raw|body|ids|spoiler_text|spoiler|content|statuses|window|items|pages)\z/,
  /\A(?:code|state|code_verifier|client_assertion|dpop|pkce_verifier|dpop_private_key)\z/,
  # The settings RSS form only. Exact, so oembed and webhook :url stay visible
  # and the JSON subscription API keeps its url parameter.
  /\Afeed_url\z/,
]
