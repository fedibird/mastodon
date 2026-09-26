# frozen_string_literal: true

require 'rails_helper'

describe WebhookService do
  # Create the status before any webhook exists so the model hook does not
  # enqueue a delivery of its own.
  let!(:status) { Fabricate(:status, text: 'webhook payload') }
  let!(:enabled) { Fabricate(:webhook, url: 'https://example.com/enabled', events: ['status.created'], enabled: true) }
  let!(:disabled) { Fabricate(:webhook, url: 'https://example.com/disabled', events: ['status.created'], enabled: false) }
  let!(:unrelated) { Fabricate(:webhook, url: 'https://example.com/other', events: ['report.created'], enabled: true) }

  before do
    allow(Webhooks::DeliveryWorker).to receive(:perform_async)
  end

  describe '#call' do
    it 'enqueues only enabled webhooks subscribed to the event' do
      described_class.new.call('status.created', status)

      expect(Webhooks::DeliveryWorker).to have_received(:perform_async).with(enabled.id, kind_of(String)).once
      expect(Webhooks::DeliveryWorker).to_not have_received(:perform_async).with(disabled.id, anything)
      expect(Webhooks::DeliveryWorker).to_not have_received(:perform_async).with(unrelated.id, anything)
    end

    it 'serializes the v4.2.13 event envelope' do
      captured = nil
      allow(Webhooks::DeliveryWorker).to receive(:perform_async) { |_id, body| captured = body }

      described_class.new.call('status.created', status)

      payload = JSON.parse(captured)
      expect(payload['event']).to eq 'status.created'
      expect(Time.iso8601(payload['created_at'])).to be_a(Time)
      expect(payload['object']).to be_a(Hash)
      expect(payload['object']['id']).to eq status.id.to_s
    end
  end
end
