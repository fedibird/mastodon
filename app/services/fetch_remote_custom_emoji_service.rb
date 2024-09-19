# frozen_string_literal: true

class FetchRemoteCustomEmojiService < BaseService
  def call(url, prefetched_body = nil)
    if prefetched_body.nil?
      resource_url, resource_options = FetchResourceService.new.call(url)
    else
      resource_url     = url
      resource_options = { prefetched_body: prefetched_body }
    end

    ActivityPub::FetchRemoteCustomEmojiService.new.call(resource_url, **resource_options) unless resource_url.nil?
  end
end
