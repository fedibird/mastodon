# frozen_string_literal: true

require 'rails_helper'
require 'stringio'

describe WebUiDomains::Middleware do
  def request_env(host, path: '/')
    {
      'HTTP_HOST' => host,
      'HTTPS' => 'on',
      'rack.url_scheme' => 'https',
      'SERVER_PORT' => '443',
      'SERVER_NAME' => host,
      'REMOTE_ADDR' => '203.0.113.10',
      'REQUEST_METHOD' => 'GET',
      'SCRIPT_NAME' => '',
      'PATH_INFO' => path,
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new(''),
      'rack.errors' => StringIO.new(''),
    }
  end

  it 'is not installed in front of the session store' do
    klasses = Rails.application.middleware.map { |entry| entry.respond_to?(:klass) ? entry.klass : entry }

    expect(klasses).not_to include(described_class)
    expect(Rails.application.config.session_options[:key]).to eq('_mastodon_session')
  end

  it 'records a closed-gate context and passes the response through' do
    previous = Rails.configuration.x.web_ui_domains
    Rails.configuration.x.web_ui_domains = WebUiDomains::Configuration.load!(
      '1.fedibird.com',
      domains: WebUiDomains::ConfiguredDomains.new(
        local_domain: 'fedibird.social',
        web_domain: 'fedibird.com',
        alternate_domains: ['old.fedibird.com'],
        use_https: true,
      ),
    )
    app = lambda do |env|
      context = env.fetch(described_class::CONTEXT_KEY)
      [200, { 'Content-Type' => 'text/plain' }, ["#{context.mode}:#{context.access_origin}"]]
    end

    status, _headers, body = described_class.new(app).call(request_env('1.fedibird.com'))

    expect(status).to eq(200)
    expect(body.join).to eq('additional_candidate:')
    expect(Rails.application.config.hosts).not_to include('1.fedibird.com')
  ensure
    Rails.configuration.x.web_ui_domains = previous
  end
end

describe 'production-like host authorization' do
  def request_env(host, path)
    {
      'HTTP_HOST' => host,
      'rack.url_scheme' => 'https',
      'HTTPS' => 'on',
      'SERVER_PORT' => '443',
      'SERVER_NAME' => host,
      'REMOTE_ADDR' => '203.0.113.10',
      'REQUEST_METHOD' => 'GET',
      'SCRIPT_NAME' => '',
      'PATH_INFO' => path,
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new(''),
    }
  end

  it 'allows only the legacy names and still excludes /health' do
    list = WebUiDomains::HostAuthorizationList.legacy(
      local_domain: 'fedibird.social',
      web_domain: 'fedibird.com',
      alternate_domains: ['old.fedibird.com'],
    )
    app = ->(_env) { [200, { 'Content-Type' => 'text/plain' }, ['ok']] }
    stack = ActionDispatch::HostAuthorization.new(app, list, exclude: ->(request) { request.path == '/health' })
    call = ->(host, path) { stack.call(request_env(host, path)).first }

    expect(list).to eq(['fedibird.social', 'fedibird.com', 'old.fedibird.com'])
    expect(call.call('fedibird.com', '/')).to eq(200)
    expect(call.call('fedibird.social', '/')).to eq(200)
    expect(call.call('old.fedibird.com', '/')).to eq(200)
    expect(call.call('1.fedibird.com', '/')).to eq(403)
    expect(call.call('1.fedibird.com', '/health')).to eq(200)
  end
end
