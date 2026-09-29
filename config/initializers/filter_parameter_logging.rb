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
]
