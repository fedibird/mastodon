# frozen_string_literal: true

source 'https://rubygems.org'
ruby '>= 2.7.0', '< 3.3.0'

gem 'pkg-config', '~> 1.4'

gem 'puma', '~> 5.4'
gem 'rails', '~> 6.1.4'
gem 'sprockets', '~> 3.7.2'
gem 'thor', '~> 1.1'
gem 'rack', '~> 2.2.3'

gem 'hamlit-rails', '~> 0.2'
gem 'pg', '~> 1.2'
gem 'makara', '~> 0.5'
gem 'pghero'
gem 'dotenv-rails', '~> 2.8'

gem 'aws-sdk-s3', '~> 1.98', require: false
gem 'fog-core', '<= 2.1.0'
gem 'fog-openstack', '~> 0.3', require: false
gem 'kt-paperclip', '~> 7.1', github: 'fedibird/kt-paperclip', ref: '0442dbfbd3877a581e17621537831d88433dfe27'
gem 'blurhash', '~> 0.1'
gem "thumbhash", "~> 0.0.1"

gem 'active_model_serializers', '~> 0.10'
gem 'active_record_extended', git: 'https://github.com/GeorgeKaraszi/ActiveRecordExtended.git', ref: '8c9d1a3e72aabf1a4f1fbeeb93a6e0f170fd0c3e'
gem 'order_as_specified'
gem 'addressable', '~> 2.8'
gem 'bootsnap', '~> 1.18.0', require: false
gem 'browser'
gem 'charlock_holmes', '~> 0.7.7'
gem 'iso-639'
gem 'chewy', '~> 7.6'
gem 'cld3', '~> 3.5.3'
gem 'devise', '~> 4.9'
gem 'devise-two-factor'

group :pam_authentication, optional: true do
  gem 'devise_pam_authenticatable2', '~> 9.2'
end

gem 'net-ldap', '~> 0.18'

gem 'omniauth', '~> 2.0'
gem 'omniauth-cas', '~> 3.0.0.beta.1'
gem 'omniauth_openid_connect', '~> 0.6.1'
gem 'omniauth-rails_csrf_protection', '~> 1.0'
gem 'omniauth-saml', '~> 2.0'

gem 'color_diff', '~> 0.1'
gem 'discard', '~> 1.2'
gem 'doorkeeper', '~> 5.6'
gem 'faraday-httpclient'
gem 'ed25519', '~> 1.2'
gem 'fast_blank', '~> 1.0'
gem 'fastimage'
gem 'hiredis', '~> 0.6'
gem 'redis-namespace', '~> 1.8'
gem 'htmlentities', '~> 4.3'
gem 'http', '~> 5.2.0'
gem 'http_accept_language', '~> 2.1'
gem 'httplog', '~> 1.7.0', require: false
gem 'idn-ruby', require: 'idn'
gem 'kaminari', '~> 1.2'
gem 'link_header', '~> 0.0'
gem 'mime-types', '~> 3.3.1', require: 'mime/types/columnar'
gem 'nokogiri', '~> 1.12'
gem 'nsa', '~> 0.2'
gem 'oj', '~> 3.12'
gem 'ox', '~> 2.14'
gem 'parslet'
gem 'parallel', '~> 1.20'
gem 'posix-spawn'
gem 'pundit', '~> 2.1'
gem 'premailer-rails'
gem 'rack-attack', '~> 6.5'
gem 'rack-cors', '~> 1.1', require: 'rack/cors'
gem 'rails-i18n', '~> 6.0'
gem 'rails-settings-cached', '~> 0.6', git: 'https://github.com/mastodon/rails-settings-cached.git', branch: 'v0.6.6-aliases-true'
gem 'redcarpet', '~> 3.6'
gem 'redis', '~> 4.5', require: ['redis', 'redis/connection/hiredis']
gem 'mario-redis-lock', '~> 1.2', require: 'redis_lock'
gem 'mojinizer'
gem 'rqrcode', '~> 2.0'
gem 'ruby-progressbar', '~> 1.11'
gem 'sanitize', '~> 6.0'
gem 'scenic', '~> 1.5'
gem 'sidekiq', '~> 7.3'
gem 'sidekiq-scheduler', '~> 5.0'
gem 'sidekiq-unique-jobs', '~> 8.0.10'
gem 'sidekiq-bulk', '~>0.2.0'
gem 'simple-navigation', '~> 4.3'
gem 'simple_form', '~> 5.1'
gem 'sprockets-rails', '~> 3.2', require: 'sprockets/railtie'
gem 'stoplight', '~> 3.0.1'
gem 'strong_migrations', '~> 0.7'
gem 'tty-prompt', '~> 0.23', require: false
gem 'twitter-text', '~> 3.1.0'
gem 'tzinfo-data', '~> 1.2021'
gem 'webpacker', '~> 5.4'
gem 'webpush', git: 'https://github.com/ClearlyClaire/webpush.git', ref: 'f14a4d52e201128b1b00245d11b6de80d6cfdcd9'
gem 'webauthn', '~> 2.5'
gem 'rubyzip', '~> 2.3'

gem 'json-ld'
gem 'json-ld-preloaded', '~> 3.1'
gem 'rdf-normalize', '~> 0.4'

group :development, :test do
  gem 'fabrication', '~> 2.22'
  gem 'fuubar', '~> 2.5'
  gem 'i18n-tasks', '~> 0.9', require: false
  gem 'pry-byebug', '~> 3.9'
  gem 'pry-rails', '~> 0.3'
  gem 'rspec-rails', '~> 5.0'
end

group :production, :test do
  gem 'private_address_check', '~> 0.5'
end

group :test do
  gem 'capybara', '~> 3.35'
  gem 'climate_control', '~> 0.2'
  gem 'faker', '~> 2.18'
  gem 'microformats', '~> 4.2'
  gem 'rails-controller-testing', '~> 1.0'
  gem 'rspec-sidekiq', '~> 3.1'
  gem 'simplecov', '~> 0.21', require: false
  gem 'webmock', '~> 3.13'
  gem 'parallel_tests', '~> 3.7'
  gem 'rspec_junit_formatter', '~> 0.4'
end

group :development do
  gem 'active_record_query_trace', '~> 1.8'
  gem 'annotate', '~> 3.1'
  gem 'better_errors', '~> 2.9'
  gem 'binding_of_caller', '~> 1.0'
  gem 'bullet', '~> 6.1'
  gem 'letter_opener', '~> 1.7'
  gem 'letter_opener_web', '~> 1.4'
  gem 'memory_profiler'
  gem 'rubocop', '~> 1.18', require: false
  gem 'parser', '~> 3.2.2.0', require: false
  gem 'rubocop-rails', '~> 2.11', require: false
  gem 'brakeman', '~> 5.1', require: false
  gem 'bundler-audit', '~> 0.8', require: false

  gem 'capistrano', '~> 3.16'
  gem 'capistrano-rails', '~> 1.6'
  gem 'capistrano-rbenv', '~> 2.2'
  gem 'capistrano-yarn', '~> 2.0'

  gem 'stackprof'
end

group :production do
  gem 'lograge', '~> 0.11'
end

gem 'concurrent-ruby', '1.3.4', require: false
gem 'connection_pool', require: false

gem 'xorcist', '~> 1.1'
gem 'cocoon', '~> 1.2'
gem 'mail', '2.7.1'

gem "net-http", "~> 0.4.1"
gem 'net-pop'
gem 'net-imap'

gem "globalid", "~> 1.0"
