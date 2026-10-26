# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Owner-only display order. Saved files and remote video/audio stay in
      # the article order. The WebUI follows this list instead of the default
      # "first attachment type wins" gallery, which would hide either the
      # images or the saved video.
      class Sequence
        def self.for(projection)
          new(projection).to_a
        end

        def initialize(projection)
          @projection = projection
          @resource = projection&.external_resource
        end

        def to_a
          return [] if @resource.nil?

          Array(@resource.media_candidates).filter_map { |candidate| entry(candidate) }
        end

        private

        def entry(candidate)
          link = links[MediaDigest.url_digest(candidate['url'])]
          if link&.media_attachment_id
            local_entry(candidate, link)
          elsif %w(video audio).include?(candidate['kind'])
            remote_entry(candidate)
          end
        end

        def local_entry(candidate, link)
          {
            type: candidate['kind'],
            delivery: 'local',
            attachment_id: link.media_attachment_id.to_s,
            position: candidate['position'],
            description: candidate['description'],
          }.compact
        end

        def remote_entry(candidate)
          {
            id: "rss-media:#{MediaDigest.url_digest(candidate['url'])[0, 16]}",
            type: candidate['kind'],
            delivery: 'remote',
            url: candidate['url'],
            position: candidate['position'],
            description: candidate['description'],
            mime_type: candidate['mime_hint'],
            external: true,
          }.compact
        end

        def links
          @links ||= @projection.external_projection_attachments.includes(:external_media_asset).each_with_object({}) do |row, memo|
            digest = row.external_media_asset&.url_digest
            memo[digest] = row if digest
          end
        end
      end
    end
  end
end
