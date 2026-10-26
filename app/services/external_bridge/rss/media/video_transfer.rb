# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Decides whether one video may be stored. The enclosure length is only
      # a hint: over the cap skips the request, under the cap is still checked
      # with HEAD. A missing Content-Length stays remote and is not measured
      # by downloading the file. A body that grows past the cap is discarded.
      class VideoTransfer
        Result = Struct.new(:body, :type, :content_type, :width, :height, :fingerprint, keyword_init: true)
        Outcome = Struct.new(:result, :terminal, :code, keyword_init: true)

        def call(candidate)
          return remote(:policy_remote) unless Policy.hybrid?

          limit = Policy.max_bytes
          hinted = candidate['length_hint']
          return remote(:video_over_cap) if hinted.is_a?(Integer) && hinted > limit

          head = HttpClient.head(candidate['url'], profile: profile(limit))
          return remote(:video_size_unknown) unless head.code.between?(200, 299) && head.content_length.present?
          return remote(:video_over_cap) if head.content_length > limit
          return remote(:video_type_rejected) unless Policy.storable_mime?(head.content_type)

          download(candidate['url'], limit, head.content_type)
        rescue Error => e
          terminal = !%w(fetch_failed rate_limited media_too_large).include?(e.code)
          e.code == 'media_too_large' ? remote(:video_over_cap) : Outcome.new(result: nil, terminal: terminal, code: e.code)
        end

        private

        def download(url, limit, expected_type)
          response = HttpClient.get(url, profile: profile(limit))
          return remote("http_#{response.code}") unless response.code.between?(200, 299)
          return remote(:video_type_rejected) unless Policy.storable_mime?(response.content_type)
          return remote(:video_type_rejected) if response.content_type != expected_type

          body = response.body.to_s.b
          return remote(:media_empty) if body.empty?
          return remote(:video_over_cap) if body.bytesize > limit

          Outcome.new(result: result_for(body, response.content_type), terminal: false, code: nil)
        end

        def result_for(body, content_type)
          type = content_type == 'video/webm' ? :webm : :mp4
          Result.new(body: body, type: type, content_type: content_type, fingerprint: Digest::SHA256.hexdigest(body))
        end

        def remote(code)
          Outcome.new(result: nil, terminal: true, code: code)
        end

        def profile(limit)
          HttpClient::FetchProfile.new(
            accept: 'video/mp4, video/webm',
            max_bytes: limit,
            asset_urls: false,
            budget_namespace: 'external_bridge:rss_media:host:',
            budget: Limits::MEDIA_HOST_BUDGET,
            content_types: Policy::STORABLE_MIME,
            truncate: false,
            timeouts: Limits::MEDIA_VIDEO_TIMEOUTS,
            url_mode: :media
          )
        end
      end
    end
  end
end
