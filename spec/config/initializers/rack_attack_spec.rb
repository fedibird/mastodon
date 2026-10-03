require 'rails_helper'

describe Rack::Attack, type: :request do # rubocop:disable Metrics/BlockLength
  def app
    Rails.application
  end

  shared_examples 'throttled endpoint' do
    context 'when the number of requests is lower than the limit' do
      it 'does not change the request status' do
        limit.times do
          request.call
          expect(response.status).to_not eq(429)
        end
      end
    end

    context 'when the number of requests is higher than the limit' do
      it 'returns http too many requests' do
        (limit * 2).times do |i|
          request.call
          expect(response.status).to eq(429) if i > limit
        end
      end
    end
  end

  let(:remote_ip) { '1.2.3.5' }

  describe 'throttle excessive sign-up requests by IP address' do
    context 'through the website' do
      let(:limit) { 25 }
      let(:request) { ->() { post path, headers: { 'REMOTE_ADDR' => remote_ip } } }

      context 'for exact path' do
        let(:path)  { '/auth' }
        it_behaves_like 'throttled endpoint'
      end

      context 'for path with format' do
        let(:path)  { '/auth.html' }
        it_behaves_like 'throttled endpoint'
      end
    end

    context 'through the API' do
      let(:limit) { 5 }
      let(:request) { ->() { post path, headers: { 'REMOTE_ADDR' => remote_ip } } }

      context 'for exact path' do
        let(:path)  { '/api/v1/accounts' }
        it_behaves_like 'throttled endpoint'
      end

      context 'for path with format' do
        let(:path)  { '/api/v1/accounts.json' }

        it 'returns http not found' do
          request.call
          expect(response.status).to eq(404)
        end
      end
    end
  end

  describe 'throttle excessive sign-in requests by IP address' do
    let(:limit) { 25 }
    let(:request) { ->() { post path, headers: { 'REMOTE_ADDR' => remote_ip } } }

    context 'for exact path' do
      let(:path)  { '/auth/sign_in' }
      it_behaves_like 'throttled endpoint'
    end

    context 'for path with format' do
      let(:path)  { '/auth/sign_in.html' }
      it_behaves_like 'throttled endpoint'
    end
  end

  describe 'throttle excessive password change requests by account' do
    let(:user) { Fabricate(:user, email: 'user@host.example') }
    let(:limit) { 10 }
    let(:period) { 10.minutes }
    let(:request) { -> { put path, headers: { 'REMOTE_ADDR' => remote_ip } } }
    let(:path) { '/auth' }

    before do
      # Test runs with LOCAL_HTTPS, so the session cookie is Secure and is only
      # stored for HTTPS requests.
      https!

      sign_in user, scope: :user

      # Unfortunately, devise's `sign_in` helper causes the `session` to be
      # loaded in the next request regardless of whether it's actually accessed
      # by the client code.
      #
      # So, we make an extra query to clear issue a session cookie instead.
      #
      # A less resource-intensive way to deal with that would be to generate the
      # session cookie manually, but this seems pretty involved.
      get '/'
    end

    it_behaves_like 'throttled endpoint'
  end

  describe 'media proxy throttles' do # rubocop:disable Metrics/BlockLength
    let(:media_proxy_path) { '/media_proxy/0/not-a-variant' }

    def request_media_proxy(ip:, headers: {})
      get media_proxy_path, headers: headers.merge('REMOTE_ADDR' => ip)
    end

    before do
      Rack::Attack.cache.reset!
    end

    it 'keeps both the per-IP limit and the unauthenticated global limit' do
      per_ip = described_class.throttles['throttle_media_proxy']
      global = described_class.throttles['throttle_media_proxy_unauthenticated_global']

      expect(per_ip.limit).to eq(300)
      expect(per_ip.period).to eq(1.minute)
      expect(global.limit).to eq(100)
      expect(global.period).to eq(600)
      expect(described_class::MEDIA_PROXY_UNAUTHENTICATED_LIMIT).to eq(100)
      expect(described_class::MEDIA_PROXY_UNAUTHENTICATED_PERIOD).to eq(600)
    end

    it 'falls back when a media proxy limit is not a positive integer' do
      expect(described_class.media_proxy_positive_integer(nil, 100)).to eq(100)
      expect(described_class.media_proxy_positive_integer('', 100)).to eq(100)
      expect(described_class.media_proxy_positive_integer('0', 100)).to eq(100)
      expect(described_class.media_proxy_positive_integer('-5', 100)).to eq(100)
      expect(described_class.media_proxy_positive_integer('10.5', 100)).to eq(100)
      expect(described_class.media_proxy_positive_integer('abc', 100)).to eq(100)
      expect(described_class.media_proxy_positive_integer('150', 100)).to eq(150)
    end

    it 'shares one anonymous bucket across source IPs and names that rule in the log' do
      allow(Rails.logger).to receive(:info).and_call_original

      statuses = Array.new(101) do |index|
        request_media_proxy(ip: format('203.0.113.%d', index + 1))
        response.status
      end

      expect(statuses.first(100)).to all(satisfy { |status| status != 429 })
      expect(statuses.last).to eq(429)
      expect(response.headers['X-RateLimit-Limit']).to eq('100')
      expect(Rails.logger).to have_received(:info).with(a_string_matching(/\ARate limit hit \(throttle\): throttle_media_proxy_unauthenticated_global - 203\.0\.113\.101 GET #{Regexp.escape(media_proxy_path)}\z/))
    end

    it 'does not apply the anonymous media proxy bucket to other paths' do
      101.times do |index|
        request_media_proxy(ip: format('203.0.113.%d', index + 1))
      end

      get '/', headers: { 'REMOTE_ADDR' => '203.0.113.200' }

      expect(response.status).to_not eq(429)
    end

    it 'does not count a signed-in web session toward the anonymous bucket' do
      user = Fabricate(:user)
      # LOCAL_HTTPS makes the session cookie Secure. Rack::Attack runs after
      # Warden and only sees this user when that cookie is actually sent.
      https!
      sign_in user, scope: :user
      get '/'

      101.times do
        request_media_proxy(ip: '198.51.100.10')
        expect(response.status).to_not eq(429)
      end
    end

    it 'does not count an OAuth token toward the anonymous bucket' do
      user = Fabricate(:user)
      token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
      headers = { 'Authorization' => "Bearer #{token.token}" }

      101.times do
        request_media_proxy(ip: '198.51.100.20', headers: headers)
        expect(response.status).to_not eq(429)
      end
    end

    it 'leaves the anonymous bucket intact after authenticated media proxy requests' do
      user = Fabricate(:user)
      token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read')
      headers = { 'Authorization' => "Bearer #{token.token}" }

      40.times do
        request_media_proxy(ip: '198.51.100.30', headers: headers)
        expect(response.status).to_not eq(429)
      end

      statuses = Array.new(101) do |index|
        request_media_proxy(ip: format('198.51.100.%d', index + 40))
        response.status
      end

      expect(statuses.first(100)).to all(satisfy { |status| status != 429 })
      expect(statuses.last).to eq(429)
    end
  end
end
