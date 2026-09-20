# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FanOutOnWriteService, type: :service do # rubocop:disable Metrics/BlockLength
  describe 'streaming searchable text' do # rubocop:disable Metrics/BlockLength
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

    it 'attaches Rails filterable_text to the anonymous public payload' do
      status = Fabricate(:status, account: author, text: "URL CHECK\nhttps://example.com/filter-url-test")
      json = dumped_payload(status)
      payload = json['payload'] || json[:payload]
      attached = payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]

      expect(attached).to eq status.proper.filterable_text
      expect(status.searchable_text).not_to include('example.com')
      expect(attached).to include('example.com')
      expect(attached).to include('URL CHECK')
    end

    it 'does not add searchable_text or filterable_text to the REST serializer' do
      status = Fabricate(:status, account: author, text: 'hello https://example.com/filter-url-test')
      serialized = InlineRenderer.render(status, nil, :status)

      expect(serialized).not_to have_key(:searchable_text)
      expect(serialized).not_to have_key('searchable_text')
      expect(serialized).not_to have_key(:filterable_text)
      expect(serialized).not_to have_key('filterable_text')
      expect(serialized).not_to have_key(FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY)
      expect(serialized).not_to have_key(:_fedibird_searchable_text)
    end

    it 'includes a referenced status public URL in the streaming field' do
      referenced = Fabricate(:status, account: author, text: 'original')
      referencing = Fabricate(:status, account: author, text: 'see this')
      Fabricate(:status_reference, status: referencing, target_status: referenced)
      json = dumped_payload(referencing)
      payload = json['payload'] || json[:payload]
      attached = payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]
      url = ActivityPub::TagManager.instance.url_for(referenced)

      expect(attached).to eq referencing.proper.filterable_text
      expect(attached).to include(url)
      expect(referencing.searchable_text).not_to include(url)
    end

    it 'includes a referenced status ActivityPub URI in the streaming field' do
      remote = Fabricate(:account, domain: 'example.social', username: 'bob', url: 'https://example.social/@bob')
      referenced = Fabricate(
        :status,
        account: remote,
        text: 'remote original',
        uri: 'https://example.social/users/bob/statuses/123',
        url: 'https://example.social/@bob/123'
      )
      referencing = Fabricate(:status, account: author, text: 'see remote')
      Fabricate(:status_reference, status: referencing, target_status: referenced)
      json = dumped_payload(referencing)
      payload = json['payload'] || json[:payload]
      attached = payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]

      expect(attached).to include(referenced.url)
      expect(attached).to include(referenced.uri)
      expect(referencing.searchable_text).not_to include('example.social')
    end

    it 'uses the original status filterable_text for a group reblog payload' do
      referenced = Fabricate(:status, account: author, text: 'original')
      original = Fabricate(:status, account: author, text: 'innerword https://example.com/filter-url-test')
      Fabricate(:status_reference, status: original, target_status: referenced)
      reblog = Fabricate(:status, account: author, reblog: original)
      json = dumped_payload(reblog, reblog: true)
      payload = json['payload'] || json[:payload]
      attached = payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]
      referenced_url = ActivityPub::TagManager.instance.url_for(referenced)
      referenced_uri = ActivityPub::TagManager.instance.uri_for(referenced)

      expect(attached).to eq original.filterable_text
      expect(attached).to eq reblog.proper.filterable_text
      expect(attached).to include('innerword')
      expect(original.searchable_text).not_to include('example.com')
      expect(attached).to include('example.com')
      expect(attached).to include(referenced_url)
      expect(attached).to include(referenced_uri)
    end

    it 'does not attach searchable_text to a nested quote object' do
      quoted = Fabricate(:status, account: author, text: 'quoted body')
      status = Fabricate(:status, account: author, text: 'hello quote', quote: quoted)
      json = dumped_payload(status)
      payload = json['payload'] || json[:payload]
      quote = payload['quote'] || payload[:quote]

      expect(payload[FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY]).to eq status.proper.filterable_text
      expect(quote).to be_present
      expect(quote).not_to have_key(FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY)
      expect(quote).not_to have_key(:_fedibird_searchable_text)
      expect(quote).not_to have_key('_fedibird_searchable_text')
    end
  end
end
