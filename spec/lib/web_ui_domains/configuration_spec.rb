# frozen_string_literal: true

require 'rails_helper'

describe WebUiDomains::Configuration do
  def domains_for(local_domain: 'fedibird.social', web_domain: 'fedibird.com', alternate_domains: ['old.fedibird.com'], use_https: true)
    WebUiDomains::ConfiguredDomains.new(
      local_domain: local_domain,
      web_domain: web_domain,
      alternate_domains: alternate_domains,
      use_https: use_https,
    )
  end

  def parse(raw, **overrides)
    described_class.parse(raw, domains: domains_for(**overrides))
  end

  def load(raw, **overrides)
    described_class.load!(raw, domains: domains_for(**overrides))
  end

  describe 'unset values' do
    it 'keeps an empty candidate list for nil, blank, and empty elements' do
      [nil, '', '   ', ' , , '].each do |raw|
        configuration = load(raw)

        expect(configuration.additional_hosts).to eq([])
        expect(configuration.rejected?).to be(false)
        expect(configuration.strict_mode_enabled?).to be(false)
      end
    end

    it 'does not apply the new hostname rules to an existing localhost port' do
      configuration = load(
        nil,
        local_domain: 'localhost:3000',
        web_domain: 'localhost:3000',
        alternate_domains: [],
        use_https: false,
      )

      expect(configuration.canonical_origin).to eq('http://localhost:3000')
      expect(configuration.rp_id).to eq('localhost')
      expect(configuration.rejected?).to be(false)
    end
  end

  describe 'accepted names' do
    it 'normalizes whitespace, case, and IDN without opening strict mode' do
      configuration = load(' CF.Fedibird.COM , , 1.fedibird.com , 例.fedibird.com ')

      expect(configuration.additional_hosts).to eq(['cf.fedibird.com', '1.fedibird.com', 'xn--fsq.fedibird.com'])
      expect(configuration.canonical_origin).to eq('https://fedibird.com')
      expect(configuration.strict_mode_enabled?).to be(false)
      expect(configuration).to be_frozen
      expect(configuration.additional_hosts).to be_frozen
      expect { configuration.additional_hosts << 'extra.fedibird.com' }.to raise_error(FrozenError)
    end

    it 'accepts a child of a private-suffix registrable domain' do
      configuration = load(
        '1.foo.github.io',
        local_domain: 'foo.github.io',
        web_domain: 'foo.github.io',
        alternate_domains: [],
      )

      expect(configuration.additional_hosts).to eq(['1.foo.github.io'])
    end

    it 'accepts a subdomain of a multi-label public suffix' do
      configuration = load(
        '1.example.co.uk',
        local_domain: 'example.social',
        web_domain: 'example.co.uk',
        alternate_domains: [],
      )

      expect(configuration.additional_hosts).to eq(['1.example.co.uk'])
    end
  end

  describe 'rejected names' do
    [
      ['https://cf.fedibird.com', 'scheme'],
      ['cf.fedibird.com/web', 'path'],
      ['cf.fedibird.com?x=1', 'query'],
      ['cf.fedibird.com#x', 'fragment'],
      ['user@cf.fedibird.com', 'userinfo'],
      ['cf.fedibird.com:443', 'port'],
      ['*.fedibird.com', 'wildcard'],
      ['cf.fedibird.com.', 'trailing dot'],
      ['cf..fedibird.com', 'empty label'],
      ['.cf.fedibird.com', 'empty label'],
      ['cf-.fedibird.com', 'DNS label'],
      ["cf.fedi\nbird.com", 'control character'],
      ['127.0.0.1', 'IP'],
      ['127.1', 'IP'],
      ['0x7f.0.0.1', 'IP'],
      ['0177.0.0.1', 'IP'],
      ['2130706433', 'IP'],
      ['[::1]', 'IP'],
      ['::1', 'IP'],
    ].each do |token, kind|
      it "rejects the whole list when it contains #{kind} (#{token.inspect})" do
        configuration = parse("1.fedibird.com, #{token}")

        expect(configuration.rejected?).to be(true)
        expect(configuration.additional_hosts).to eq([])
        expect(configuration.error_message).to include('no host was adopted')
        expect(configuration.error_message).to include(token.inspect)
        expect { load("1.fedibird.com, #{token}") }.to raise_error(WebUiDomains::ConfigurationError, /no host was adopted/)
      end
    end

    it 'rejects duplicates after IDN normalization and keeps none of the other names' do
      configuration = parse('1.fedibird.com, CAFÉ.fedibird.com, xn--caf-dma.fedibird.com, 2.fedibird.com')

      expect(configuration.additional_hosts).to eq([])
      expect(configuration.error_message).to include('xn--caf-dma.fedibird.com')
      expect(configuration.error_message).not_to include('2.fedibird.com is')
    end

    it 'rejects a collision with the normalized local, web, or alternate host' do
      expect(parse('fedibird.com').error_message).to include('collides')
      expect(parse('Fedibird.social').error_message).to include('collides')
      expect(parse('old.fedibird.com').error_message).to include('collides')
      expect(parse('old.fedibird.com', alternate_domains: ['OLD.Fedibird.com:443']).additional_hosts).to eq([])
    end

    it 'rejects siblings, lookalike suffixes, and a different registrable domain' do
      expect(parse('notfedibird.com').rejected?).to be(true)
      expect(parse('fedibird.com.evil.com').rejected?).to be(true)
      expect(parse('1.example.com').rejected?).to be(true)
      expect(parse('2.fedibird.com', web_domain: '1.fedibird.com', alternate_domains: []).rejected?).to be(true)
      expect(parse('bar.github.io', local_domain: 'foo.github.io', web_domain: 'foo.github.io', alternate_domains: []).rejected?).to be(true)
    end

    it 'rejects additional names when the RP ID is a public suffix' do
      localhost = parse('foo.localhost', local_domain: 'localhost:3000', web_domain: 'localhost:3000', alternate_domains: [], use_https: false)
      suffix = parse('foo.co.uk', local_domain: 'co.uk', web_domain: 'co.uk', alternate_domains: [])

      expect(localhost.error_message).to include('public suffix')
      expect(suffix.error_message).to include('public suffix')
      expect(localhost.additional_hosts).to eq([])
    end
  end

  describe 'existing identity' do
    it 'does not rewrite reserved domains or the legacy host allow list' do
      alternate = ['old.fedibird.com']
      configuration = load('1.fedibird.com', alternate_domains: alternate)
      legacy = WebUiDomains::HostAuthorizationList.legacy(
        local_domain: 'fedibird.social',
        web_domain: 'fedibird.com',
        alternate_domains: alternate,
      )
      same_host = WebUiDomains::HostAuthorizationList.legacy(
        local_domain: 'fedibird.com',
        web_domain: 'fedibird.com',
        alternate_domains: [],
      )

      expect(alternate).to eq(['old.fedibird.com'])
      expect(legacy).to eq(['fedibird.social', 'fedibird.com', 'old.fedibird.com'])
      expect(legacy).not_to include('1.fedibird.com')
      expect(same_host).to eq(['fedibird.com', 'fedibird.com'])
      expect(configuration.web_host).to eq('fedibird.com')
      expect(configuration.local_host).to eq('fedibird.social')
    end

    it 'leaves the booted canonical origin and WebAuthn configuration unchanged' do
      origin = "#{Rails.configuration.x.use_https ? 'https' : 'http'}://#{Rails.configuration.x.web_domain}"

      expect(Rails.configuration.x.web_ui_domains.additional_hosts).to eq([])
      expect(Rails.configuration.x.web_ui_domains.strict_mode_enabled?).to be(false)
      expect(Rails.configuration.x.web_ui_domains.canonical_origin).to eq(origin)
      expect(WebAuthn.configuration.allowed_origins).to eq([origin])
      expect(WebAuthn.configuration.rp_id).to be_nil
      expect(Rails.application.config.hosts).not_to include('1.fedibird.com')
      expect(Rails.application.config.session_options[:key]).to eq('_mastodon_session')
    end

    it 'does not change PlayerResolver or TagManager when a candidate list is parsed' do
      provider = ExternalBridge::RSS::PlayerResolver::GenericProvider.new(
        'https://remote.example/watch/abcd',
        'https://remote.example/embed/abcd',
        'https://remote.example',
      )
      extra = "1.#{Rails.configuration.x.web_domain.sub(/:\d+\z/, '')}"

      expect do
        load('cdn.example.test', local_domain: 'example.test', web_domain: 'example.test', alternate_domains: [])
      end.not_to change {
        [
          provider.send(:instance_host?, 'cdn.example.test'),
          Rails.configuration.x.web_domain,
          Rails.configuration.x.local_domain,
          Rails.configuration.x.alternate_domains.dup,
          ActionMailer::Base.default_url_options.dup,
        ]
      }
      expect(TagManager.instance.web_domain?(extra)).to be(false)
      expect(TagManager.instance.local_url?("https://#{extra}/users/alice")).to be_falsey
    end
  end
end
