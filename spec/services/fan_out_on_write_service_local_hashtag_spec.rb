# frozen_string_literal: true

require 'rails_helper'

# Fedibird intentionally does not provide local-only hashtag feeds.
# Mastodon v4.2 publishes timeline:hashtag:<tag>:local for local posts.
# This fork must keep that channel unpublished.
RSpec.describe FanOutOnWriteService, type: :service do
  describe 'local hashtag streaming policy' do
    def published_channels_for(status)
      ProcessHashtagsService.new.call(status) if status.local? && status.tags.empty?

      service = described_class.new
      published = []

      allow(service).to receive(:redis).and_wrap_original do |original|
        connection = original.call
        allow(connection).to receive(:publish).and_wrap_original do |publish, channel, payload|
          published << channel
          publish.call(channel, payload)
        end
        connection
      end

      service.call(status)
      published
    end

    it 'publishes the shared hashtag channel and not a local-only channel for a local post' do
      status = Fabricate(:status, text: 'Hello #test', visibility: :public)
      channels = published_channels_for(status)

      expect(channels).to include('timeline:hashtag:test')
      expect(channels).to include('timeline:hashtag:nobot:test')
      expect(channels).not_to include('timeline:hashtag:test:local')
    end

    it 'does not publish a local-only hashtag channel for a remote post' do
      author = Fabricate(:account, domain: 'remote.example', username: 'remoteuser')
      status = Fabricate(:status, account: author, text: 'Hello #test', visibility: :public)
      # Remote text is not scanned for hashtags. ActivityPub supplies the names.
      ProcessHashtagsService.new.call(status, ['test'])
      channels = published_channels_for(status)

      expect(channels).to include('timeline:hashtag:test')
      expect(channels).not_to include('timeline:hashtag:test:local')
    end
  end
end
