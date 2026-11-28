# frozen_string_literal: true

require 'rails_helper'
require 'ipaddr'
require 'stringio'

describe WebUiDomains::RequestContext do
  def domains_for(local_domain: 'fedibird.social', web_domain: 'fedibird.com', alternate_domains: ['old.fedibird.com'], use_https: true)
    WebUiDomains::ConfiguredDomains.new(
      local_domain: local_domain,
      web_domain: web_domain,
      alternate_domains: alternate_domains,
      use_https: use_https,
    )
  end

  def configuration(raw = '1.fedibird.com,cf.fedibird.com', **overrides)
    WebUiDomains::Configuration.load!(raw, domains: domains_for(**overrides))
  end

  def request_for(host, scheme: 'https', remote_addr: '203.0.113.10', headers: {}, path: '/', https: :default)
    env = {
      'HTTP_HOST' => host,
      'rack.url_scheme' => scheme,
      'SERVER_PORT' => scheme == 'https' ? '443' : '80',
      'SERVER_NAME' => host.to_s.split(':').first.to_s,
      'REMOTE_ADDR' => remote_addr,
      'REQUEST_METHOD' => 'GET',
      'SCRIPT_NAME' => '',
      'PATH_INFO' => path,
      'QUERY_STRING' => '',
      'rack.input' => StringIO.new(''),
      'rack.errors' => StringIO.new(''),
    }
    env['HTTPS'] = 'on' if https == :default && scheme == 'https'
    env['HTTPS'] = https if https.is_a?(String)
    ActionDispatch::Request.new(env.merge(headers))
  end

  def context_for(host, configuration:, gate: WebUiDomains::Gate.closed, trusted_proxies: :none, **options)
    described_class.build(
      request_for(host, **options),
      configuration: configuration,
      gate: gate,
      trusted_proxies: trusted_proxies,
    )
  end

  let(:candidates) { configuration }

  describe 'roles' do
    it 'separates the canonical origin from a verified additional entrance' do
      context = context_for(
        '1.fedibird.com',
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        headers: { 'HTTP_ORIGIN' => 'https://evil.example' },
      )

      expect(context.mode).to eq(:strict)
      expect(context.strict_mode?).to be(true)
      expect(context.canonical_origin).to eq('https://fedibird.com')
      expect(context.access_origin).to eq('https://1.fedibird.com')
      expect(context.observed_origin).to eq('https://1.fedibird.com')
      expect(context.host_roles).to eq([:additional])
    end

    it 'keeps a consistent candidate closed unless a test gate is injected' do
      context = context_for('1.Fedibird.COM', configuration: candidates)

      expect(context.mode).to eq(:additional_candidate)
      expect(context.normalized_host).to eq('1.fedibird.com')
      expect(context.strict_mode?).to be(false)
      expect(context.access_origin).to be_nil
      expect(context.failure_code).to be_nil
    end

    it 'classifies local, web, and alternate hosts as legacy even if the test gate is open' do
      opened = WebUiDomains::Gate.open_for_test

      expect(context_for('fedibird.com', configuration: candidates, gate: opened).host_roles).to eq([:web_domain])
      expect(context_for('fedibird.social', configuration: candidates, gate: opened).host_roles).to eq([:local_domain])
      expect(context_for('old.fedibird.com', configuration: candidates, gate: opened).host_roles).to eq([:alternate_domain])
      expect(context_for('fedibird.com', configuration: candidates, gate: opened).mode).to eq(:legacy)
      expect(context_for('fedibird.com', configuration: candidates, gate: opened).strict_mode?).to be(false)
    end

    it 'records both roles when LOCAL_DOMAIN and WEB_DOMAIN are the same host' do
      same = configuration(nil, local_domain: 'fedibird.com', web_domain: 'fedibird.com', alternate_domains: [])

      expect(context_for('fedibird.com', configuration: same).host_roles).to eq([:web_domain, :local_domain])
      expect(context_for('fedibird.com', configuration: same).mode).to eq(:legacy)
    end

    it 'does not let an environment variable or the Origin header open an entrance' do
      previous = ENV['WEB_UI_DOMAINS_READY']
      ENV['WEB_UI_DOMAINS_READY'] = 'true'
      context = context_for(
        '1.fedibird.com',
        configuration: candidates,
        headers: {
          'HTTP_ORIGIN' => 'https://evil.example',
          'HTTP_X_WEB_UI_DOMAINS_READY' => '1',
        },
      )

      expect(WebUiDomains::Gate.closed.enabled?).to be(false)
      expect(candidates.strict_mode_enabled?).to be(false)
      expect(context.mode).to eq(:additional_candidate)
      expect(context.access_origin).to be_nil
      expect(context.observed_origin).to eq('https://1.fedibird.com')
    ensure
      ENV['WEB_UI_DOMAINS_READY'] = previous
    end
  end

  describe 'forwarded headers' do
    it 'rejects two allow-listed hosts that disagree and does not adopt the forwarded host' do
      request = request_for('1.fedibird.com', headers: { 'HTTP_X_FORWARDED_HOST' => 'cf.fedibird.com' })
      context = described_class.build(
        request,
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        trusted_proxies: :none,
      )

      expect(request.host).to eq('cf.fedibird.com')
      expect(context.mode).to eq(:rejected)
      expect(context.failure_code).to eq(:forwarded_host_mismatch)
      expect(context.normalized_host).to eq('1.fedibird.com')
      expect(context.observed_origin).to eq('https://1.fedibird.com')
      expect(context.access_origin).to be_nil
      expect(context.strict_mode?).to be(false)
    end

    it 'rejects multiple forwarded values instead of using the last one' do
      request = request_for('1.fedibird.com', headers: { 'HTTP_X_FORWARDED_HOST' => '1.fedibird.com, fedibird.com' })
      context = described_class.build(request, configuration: candidates, gate: WebUiDomains::Gate.open_for_test, trusted_proxies: :none)

      expect(request.host).to eq('fedibird.com')
      expect(context.failure_code).to eq(:forwarded_host_multiple)
      expect(context.access_origin).to be_nil
    end

    it 'treats an explicit 443 and an omitted port as the same HTTPS authority' do
      context = context_for(
        '1.fedibird.com:443',
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        headers: { 'HTTP_X_FORWARDED_HOST' => '1.fedibird.com', 'HTTP_X_FORWARDED_PORT' => '443' },
      )

      expect(context.mode).to eq(:strict)
      expect(context.access_origin).to eq('https://1.fedibird.com')
    end

    it 'rejects an RFC Forwarded header without parsing it' do
      context = context_for(
        '1.fedibird.com',
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        headers: { 'HTTP_FORWARDED' => 'for=203.0.113.9;host=fedibird.com;proto=http' },
      )

      expect(context.failure_code).to eq(:forwarded_header_present)
      expect(context.access_origin).to be_nil
    end

    it 'rejects multiple or non-443 forwarded ports' do
      multiple = context_for('1.fedibird.com', configuration: candidates, gate: WebUiDomains::Gate.open_for_test, headers: { 'HTTP_X_FORWARDED_PORT' => '443, 80' })
      mismatched = context_for('1.fedibird.com', configuration: candidates, gate: WebUiDomains::Gate.open_for_test, headers: { 'HTTP_X_FORWARDED_PORT' => '8443' })
      explicit = context_for('1.fedibird.com:8443', configuration: candidates, gate: WebUiDomains::Gate.open_for_test)

      expect(multiple.failure_code).to eq(:forwarded_port_multiple)
      expect(mismatched.failure_code).to eq(:forwarded_port_mismatch)
      expect(explicit.failure_code).to eq(:port_not_https)
    end

    it 'rejects a scheme downgrade from a trusted proxy' do
      context = context_for(
        '1.fedibird.com',
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        remote_addr: '203.0.113.10',
        trusted_proxies: [IPAddr.new('203.0.113.10')],
        headers: { 'HTTP_X_FORWARDED_PROTO' => 'http' },
      )

      expect(context.failure_code).to eq(:scheme_downgrade)
      expect(context.strict_mode?).to be(false)
    end

    it 'does not promote an untrusted forwarded proto, even when Rails does' do
      request = request_for('1.fedibird.com', scheme: 'http', https: false, headers: { 'HTTP_X_FORWARDED_PROTO' => 'https, http' })
      context = described_class.build(request, configuration: candidates, gate: WebUiDomains::Gate.open_for_test, trusted_proxies: :none)

      expect(context.failure_code).to eq(:forwarded_proto_multiple)
      expect(context.access_origin).to be_nil
    end

    it 'rejects an untrusted upgrade that would make request.ssl? true' do
      request = request_for(
        '1.fedibird.com',
        scheme: 'http',
        https: false,
        remote_addr: '203.0.113.50',
        headers: { 'HTTP_X_FORWARDED_PROTO' => 'https', 'HTTP_X_FORWARDED_FOR' => '10.0.0.8' },
      )
      context = described_class.build(
        request,
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        trusted_proxies: [IPAddr.new('10.0.0.0/8')],
      )

      expect(request.ssl?).to be(true)
      expect(context.failure_code).to eq(:untrusted_forwarded_scheme)
      expect(context.strict_mode?).to be(false)
    end

    it 'accepts TLS terminated by the immediate trusted peer and ignores the client address' do
      request = request_for(
        '1.fedibird.com',
        scheme: 'http',
        https: false,
        remote_addr: '10.0.0.8',
        headers: { 'HTTP_X_FORWARDED_PROTO' => 'https', 'HTTP_X_FORWARDED_FOR' => '203.0.113.50' },
      )
      context = described_class.build(
        request,
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        trusted_proxies: [IPAddr.new('10.0.0.0/8')],
      )

      expect(request.remote_ip).to eq('203.0.113.50')
      expect(context.mode).to eq(:strict)
      expect(context.access_origin).to eq('https://1.fedibird.com')
    end

    it 'keeps a legacy host in legacy mode when forwarding disagrees' do
      context = context_for(
        'fedibird.com',
        configuration: candidates,
        gate: WebUiDomains::Gate.open_for_test,
        headers: { 'HTTP_X_FORWARDED_HOST' => '1.fedibird.com' },
      )

      expect(context.mode).to eq(:legacy)
      expect(context.failure_code).to be_nil
      expect(context.forwarding_consistent?).to be(false)
      expect(context.forwarding_failure_code).to eq(:forwarded_host_mismatch)
      expect(context.access_origin).to be_nil
    end
  end

  describe 'negative entrances' do
    it 'rejects plain HTTP for an additional host' do
      context = context_for('1.fedibird.com', configuration: candidates, gate: WebUiDomains::Gate.open_for_test, scheme: 'http', https: false)

      expect(context.failure_code).to eq(:scheme_not_https)
      expect(context.mode).to eq(:rejected)
    end

    it 'rejects malformed authority and unknown hosts without an access origin' do
      malformed = context_for('user@1.fedibird.com', configuration: candidates, gate: WebUiDomains::Gate.open_for_test)
      unknown = context_for('evil.example', configuration: candidates, gate: WebUiDomains::Gate.open_for_test)
      rejected = WebUiDomains::Configuration.parse('1.fedibird.com, *.fedibird.com', domains: domains_for)
      dropped = context_for('1.fedibird.com', configuration: rejected, gate: WebUiDomains::Gate.open_for_test)

      expect(malformed.mode).to eq(:rejected)
      expect(malformed.failure_code).to eq(:invalid_authority)
      expect(unknown.mode).to eq(:unrecognized)
      expect(unknown.access_origin).to be_nil
      expect(dropped.configuration_rejected?).to be(true)
      expect(dropped.mode).to eq(:unrecognized)
      expect(dropped.strict_mode?).to be(false)
    end

    it 'does not mix contexts or mutate global URL settings across threads' do
      other = configuration('1.example.co.uk', local_domain: 'example.social', web_domain: 'example.co.uk', alternate_domains: [])
      mailer = ActionMailer::Base.default_url_options.dup
      web_domain = Rails.configuration.x.web_domain
      session_key = Rails.application.config.session_options[:key]

      results = []
      results << Thread.new { [:alpha, context_for('1.fedibird.com', configuration: candidates, gate: WebUiDomains::Gate.open_for_test).access_origin] }
      results << Thread.new { [:beta, context_for('1.example.co.uk', configuration: other).mode] }
      results << Thread.new { [:closed, context_for('1.fedibird.com', configuration: candidates).mode] }
      results << Thread.new { [:legacy, context_for('fedibird.social', configuration: candidates, gate: WebUiDomains::Gate.open_for_test).mode] }
      pairs = results.map(&:value)

      expect(pairs).to contain_exactly(
        [:alpha, 'https://1.fedibird.com'],
        [:beta, :additional_candidate],
        [:closed, :additional_candidate],
        [:legacy, :legacy],
      )
      expect(WebUiDomains::Gate.closed.enabled?).to be(false)
      expect(ActionMailer::Base.default_url_options).to eq(mailer)
      expect(Rails.configuration.x.web_domain).to eq(web_domain)
      expect(Rails.application.config.session_options[:key]).to eq(session_key)
      expect(candidates.additional_hosts).to eq(['1.fedibird.com', 'cf.fedibird.com'])
    end
  end
end
