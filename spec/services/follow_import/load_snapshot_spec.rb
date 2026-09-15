# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::LoadSnapshot do
  let(:queue_stub) { instance_double(Sidekiq::Queue, size: 3, latency: 1.5) }

  before do
    allow(Sidekiq::Queue).to receive(:new).and_return(queue_stub)
    allow(Sidekiq::Stats).to receive(:new).and_return(instance_double(Sidekiq::Stats, retry_size: 9))
    allow(Sidekiq::ProcessSet).to receive(:new).and_return([
      { 'concurrency' => 5, 'queues' => ['push', 'default'] },
      { 'concurrency' => 2, 'queues' => ['pull'] },
    ])
  end

  it 'captures queue size/latency, retry size, and push/pull concurrency' do
    snapshot = described_class.capture

    expect(snapshot['queues']['default']).to eq('size' => 3, 'latency' => 1.5)
    expect(snapshot['queues']['push']).to eq('size' => 3, 'latency' => 1.5)
    expect(snapshot['queues']['pull']).to eq('size' => 3, 'latency' => 1.5)
    expect(snapshot['retry_size']).to eq 9
    expect(snapshot['push_concurrency']).to eq 5
    expect(snapshot['pull_concurrency']).to eq 2
  end

  it 'does not raise when Sidekiq stats are unavailable' do
    allow(Sidekiq::Queue).to receive(:new).and_raise(RuntimeError, 'redis down')
    allow(Sidekiq::Stats).to receive(:new).and_raise(RuntimeError, 'redis down')
    allow(Sidekiq::ProcessSet).to receive(:new).and_raise(RuntimeError, 'redis down')

    snapshot = described_class.capture

    expect(snapshot['queues']['push']['error_class']).to eq 'RuntimeError'
    expect(snapshot['retry_size_error_class']).to eq 'RuntimeError'
    expect(snapshot['concurrency_error_class']).to eq 'RuntimeError'
  end
end
