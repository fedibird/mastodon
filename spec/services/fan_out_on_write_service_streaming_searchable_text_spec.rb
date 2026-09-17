# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FanOutOnWriteService, type: :service do
  describe 'streaming searchable text' do
    let(:author) { Fabricate(:account, domain: nil, username: 'urlposter') }

    def dumped_payload(status, reblog: false)
      service = described_class.new
      dumped = if reblog
                 service.send(:render_anonymous_reblog_payload, status)
               else
                 service.send(:render_anonymous_payload, status)
               end
      Oj.load(dumped)
    end

    it 'attaches Rails searchable_text to the anonymous public payload' do
      status = Fabricate(:status, account: author, text: "URL CHECK\nhttps://example.com/filter-url-test")
      json = dumped_payload(status)
      payload = json['payload'] || json[:payload]

      expect(payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]).to eq status.proper.searchable_text
      expect(payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]).not_to include('example.com')
      expect(payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]).to include('URL CHECK')
    end

    it 'does not add searchable_text to the REST serializer' do
      status = Fabricate(:status, account: author, text: "hello https://example.com/filter-url-test")
      serialized = InlineRenderer.render(status, nil, :status)

      expect(serialized).not_to have_key(:searchable_text)
      expect(serialized).not_to have_key('searchable_text')
      expect(serialized).not_to have_key(FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY)
      expect(serialized).not_to have_key(:_fedibird_searchable_text)
    end

    it 'uses the original status searchable_text for a group reblog payload' do
      original = Fabricate(:status, account: author, text: "innerword https://example.com/filter-url-test")
      reblog = Fabricate(:status, account: author, reblog: original)
      json = dumped_payload(reblog, reblog: true)
      payload = json['payload'] || json[:payload]

      expect(payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]).to eq original.searchable_text
      expect(payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]).to include('innerword')
      expect(payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]).not_to include('example.com')
    end
  end
end
