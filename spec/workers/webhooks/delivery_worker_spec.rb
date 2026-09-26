# frozen_string_literal: true

require 'rails_helper'

describe Webhooks::DeliveryWorker do
  let(:worker) { described_class.new }
  let(:secret) { 'supersecretvalue' }
  let(:webhook) { Fabricate(:webhook, url: 'https://example.com/hook', secret: secret, events: ['status.created']) }
  let(:body) { '{"event":"status.created","created_at":"2020-01-01T00:00:00.000Z","object":{"id":"1"}}' }

  describe 'sidekiq options' do
    it 'uses the v4.2.13 push queue contract' do
      options = described_class.get_sidekiq_options

      expect(options['queue']).to eq 'push'
      expect(options['retry']).to eq 16
      expect(options['dead']).to be false
    end
  end

  describe 'perform' do
    it 'returns without error when the webhook does not exist' do
      expect(worker.perform(0, body)).to be true
    end

    it 'POSTs JSON with an HMAC-SHA256 signature of the raw body' do
      signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, body)
      stub_request(:post, webhook.url).to_return(status: 200)

      expect(Request).to receive(:new).with(:post, webhook.url, hash_including(body: body, allow_local: true)).and_call_original

      worker.perform(webhook.id, body)

      expect(a_request(:post, webhook.url).with(
        body: body,
        headers: {
          'Content-Type' => 'application/json',
          'X-Hub-Signature' => "sha256=#{signature}",
        }
      )).to have_been_made.once
    end

    it 'signs the body after applying the template' do
      webhook.update!(template: '{"hello":"{{event}}"}')
      rendered = '{"hello":"status.created"}'
      signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), secret, rendered)
      stub_request(:post, webhook.url).to_return(status: 200)

      worker.perform(webhook.id, body)

      expect(a_request(:post, webhook.url).with(
        body: rendered,
        headers: {
          'Content-Type' => 'application/json',
          'X-Hub-Signature' => "sha256=#{signature}",
        }
      )).to have_been_made.once
    end

    it 'accepts a successful response' do
      stub_request(:post, webhook.url).to_return(status: 204)

      expect { worker.perform(webhook.id, body) }.to_not raise_error
    end

    it 'does not retry an unrecoverable response' do
      stub_request(:post, webhook.url).to_return(status: 404)

      expect { worker.perform(webhook.id, body) }.to_not raise_error
    end

    it 'raises on a retryable response' do
      stub_request(:post, webhook.url).to_return(status: 500)

      expect { worker.perform(webhook.id, body) }.to raise_error(Mastodon::UnexpectedResponseError)
    end
  end
end
