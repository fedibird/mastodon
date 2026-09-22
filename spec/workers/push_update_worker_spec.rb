# frozen_string_literal: true

require 'rails_helper'

describe PushUpdateWorker do
  let(:account) { Fabricate(:account) }
  let(:status) { Fabricate(:status, account: account, text: 'home edit') }

  it 'publishes status.update when the update option is set' do
    published = []
    allow_any_instance_of(described_class).to receive(:redis).and_wrap_original do |original|
      connection = original.call
      allow(connection).to receive(:publish).and_wrap_original do |publish, channel, payload|
        published << [channel, payload]
        publish.call(channel, payload)
      end
      connection
    end

    described_class.new.perform(account.id, status.id, "timeline:#{account.id}", { 'update' => true })

    parsed = Oj.load(published.first.last)
    expect(parsed['event']).to eq 'status.update'
    expect(parsed['payload']['content']).to include('home edit')
  end
end
