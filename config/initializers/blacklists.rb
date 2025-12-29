# frozen_string_literal: true

Rails.application.configure do
  config.x.email_domains_blacklist = (ENV['EMAIL_DOMAIN_DENYLIST']  || ENV['EMAIL_DOMAIN_BLACKLIST']) || ''
  config.x.email_domains_whitelist = (ENV['EMAIL_DOMAIN_ALLOWLIST'] || ENV['EMAIL_DOMAIN_WHITELIST']) || ''

  raw = ENV['NOT_ALLOWED_FROM_NEW_ACCOUNTS'].to_s
  config.x.not_allowed_from_new_accounts = raw.strip.empty? ? [] : raw.split(/\s*,\s*/).map(&:downcase)
end
