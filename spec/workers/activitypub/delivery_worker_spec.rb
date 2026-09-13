# frozen_string_literal: true

require 'rails_helper'

describe ActivityPub::DeliveryWorker do
  include RoutingHelper

  subject { described_class.new }

  let(:sender)  { Fabricate(:account) }
  let(:payload) { 'test' }

  before do
    allow_any_instance_of(Account).to receive(:remote_followers_hash).with('https://example.com/api').and_return('somehash')
  end

  describe 'perform' do
    it 'performs a request' do
      stub_request(:post, 'https://example.com/api').to_return(status: 200)
      subject.perform(payload, sender.id, 'https://example.com/api', { 'synchronize_followers' => true })
      expect(a_request(:post, 'https://example.com/api').with(headers: { 'Collection-Synchronization' => "collectionId=\"#{account_followers_url(sender)}\", digest=\"somehash\", url=\"#{account_followers_synchronization_url(sender)}\"" })).to have_been_made.once
    end

    it 'raises when request fails' do
      stub_request(:post, 'https://example.com/api').to_return(status: 500)
      expect { subject.perform(payload, sender.id, 'https://example.com/api') }.to raise_error Mastodon::UnexpectedResponseError
    end
  end

  describe 'delivery tracking' do
    let(:tracking) { { 'type' => 'follow_import_target', 'id' => 5 } }

    it 'notifies tracking of successful delivery' do
      stub_request(:post, 'https://example.com/api').to_return(status: 200)
      expect(ActivityPub::DeliveryTracking).to receive(:delivered).with(tracking)
      subject.perform(payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking })
    end

    it 'does not notify tracking on a retryable failure (delivery may still succeed)' do
      stub_request(:post, 'https://example.com/api').to_return(status: 500)
      expect(ActivityPub::DeliveryTracking).not_to receive(:delivered)
      expect { subject.perform(payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking }) }.to raise_error Mastodon::UnexpectedResponseError
    end

    it 'does not notify tracking when the inbox is unavailable and delivery is skipped' do
      allow(DeliveryFailureTracker).to receive(:available?).with('https://example.com/api').and_return(false)
      expect(ActivityPub::DeliveryTracking).not_to receive(:delivered)
      subject.perform(payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking })
    end

    it 'notifies tracking of terminal failure once retries are exhausted' do
      expect(ActivityPub::DeliveryTracking).to receive(:failed).with(tracking)
      msg = { 'args' => [payload, sender.id, 'https://example.com/api', { 'delivery_tracking' => tracking }] }
      described_class.sidekiq_retries_exhausted_block.call(msg)
    end

    it 'tolerates a retries-exhausted message with no tracking metadata' do
      expect(ActivityPub::DeliveryTracking).not_to receive(:failed)
      msg = { 'args' => [payload, sender.id, 'https://example.com/api', {}] }
      expect { described_class.sidekiq_retries_exhausted_block.call(msg) }.not_to raise_error
    end
  end
end
