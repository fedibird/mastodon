# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Owner-only remote video and audio. These are not MediaAttachments:
      # a remote_url on MediaAttachment is what MediaProxy downloads.
      #
      # The URL is the normalized article URL. Fedibird does not fetch the
      # file in the default remote policy, so it also cannot see where a
      # browser redirect goes. The WebUI must not put the URL in the document
      # until the owner clicks play, and it sets referrerPolicy=no-referrer.
      # HTML media elements still do not guarantee the Referer header.
      class RemotePayload
        def self.for(projection)
          new(projection).to_a
        end

        def initialize(projection)
          @projection = projection
          @resource = projection&.external_resource
        end

        def to_a
          return [] if @resource.nil?

          saved = saved_digests
          Array(@resource.media_candidates).filter_map do |candidate|
            next unless %w(video audio).include?(candidate['kind'])
            next if saved.include?(MediaDigest.url_digest(candidate['url']))

            entry(candidate)
          end
        end

        private

        def saved_digests
          return [] if @projection.nil?

          @projection.external_projection_attachments.includes(:external_media_asset).filter_map do |row|
            row.external_media_asset&.url_digest
          end
        end

        def entry(candidate)
          {
            id: "rss-media:#{MediaDigest.url_digest(candidate['url'])[0, 16]}",
            type: candidate['kind'],
            url: candidate['url'],
            description: candidate['description'],
            mime_type: candidate['mime_hint'],
            delivery: 'remote',
            external: true,
          }.compact
        end
      end
    end
  end
end
