# frozen_string_literal: true

port     = ENV.fetch('PORT') { 3000 }
host     = ENV.fetch('LOCAL_DOMAIN') { "localhost:#{port}" }
web_host = ENV.fetch('WEB_DOMAIN') { host }

alternate_domains = ENV.fetch('ALTERNATE_DOMAINS') { '' }.split(/\s*,\s*/)

Rails.application.configure do
  https = Rails.env.production? || ENV['LOCAL_HTTPS'] == 'true'

  config.x.local_domain = host
  config.x.web_domain   = web_host
  config.x.use_https    = https
  config.x.use_s3       = ENV['S3_ENABLED'] == 'true'
  config.x.use_swift    = ENV['SWIFT_ENABLED'] == 'true'

  config.x.alternate_domains = alternate_domains

  # Candidates only. Strict mode is not an environment variable, and these
  # hosts are not added to config.hosts, WebAuthn, or federation identity.
  config.x.web_ui_domains = WebUiDomains::Configuration.load!(
    ENV.fetch('WEB_UI_DOMAINS', nil),
    domains: WebUiDomains::ConfiguredDomains.new(
      local_domain: host,
      web_domain: web_host,
      alternate_domains: alternate_domains,
      use_https: https
    )
  )

  config.action_mailer.default_url_options = { host: web_host, protocol: https ? 'https://' : 'http://', trailing_slash: false }

  config.x.streaming_api_base_url = ENV.fetch('STREAMING_API_BASE_URL') do
    if Rails.env.production?
      "ws#{https ? 's' : ''}://#{web_host}"
    else
      "ws://#{ENV['REMOTE_DEV'] == 'true' ? host.split(':').first : 'localhost'}:4000"
    end
  end

  unless Rails.env.test?
    config.hosts.concat(
      WebUiDomains::HostAuthorizationList.legacy(
        local_domain: host,
        web_domain: web_host,
        alternate_domains: alternate_domains
      )
    )
    config.host_authorization = { exclude: ->(request) { request.path == '/health' } }
  end

  if config.x.web_ui_domains.additional_hosts.any?
    Rails.logger.info(
      "WEB_UI_DOMAINS parsed #{config.x.web_ui_domains.additional_hosts.size} candidate host(s). " \
      'Strict mode is off, and these hosts were not added to config.hosts.'
    )
  end
end
