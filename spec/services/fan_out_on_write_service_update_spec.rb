# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FanOutOnWriteService, type: :service do
  let(:author) { Fabricate(:account, username: 'author') }
  let(:status) { Fabricate(:status, account: author, text: 'edited keyword https://example.com/after', visibility: :public) }

  it 'publishes status.update with the current filterable text' do
    service = described_class.new
    published = []

    allow(service).to receive(:redis).and_wrap_original do |original|
      connection = original.call
      allow(connection).to receive(:publish).and_wrap_original do |publish, channel, payload|
        published << [channel, payload]
        publish.call(channel, payload)
      end
      connection
    end

    service.call(status, update: true)

    payload = published.find { |channel, _message| channel == 'timeline:public' }&.last
    parsed = Oj.load(payload)

    expect(parsed['event']).to eq 'status.update'
    expect(parsed['payload']['_fedibird_searchable_text']).to include('edited keyword')
    expect(parsed['payload']['_fedibird_searchable_text']).to include('https://example.com/after')
  end
end
