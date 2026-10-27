# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Media
      # Owner-only display order. Saved files and remote video/audio stay in
      # the article order. The WebUI follows this list instead of the default
      # "first attachment type wins" gallery, which would hide either the
      # images or the saved video.
      class Sequence
        include RoutingHelper

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
          return nil if candidate['role'] == 'poster'
          return embed_entry(candidate) if candidate['kind'] == 'embed'

          link = link_for(candidate)
          if link&.media_attachment_id
            local_entry(candidate, link)
          elsif %w(video audio).include?(candidate['kind'])
            remote_entry(candidate)
          end
        end

        def embed_entry(candidate)
          chosen = PlayerResolver.choose(
            @resource.canonical_url,
            [{ priority: 1, at: 0, origin: candidate['origin'], urls: [candidate['url']] }]
          )
          return nil if chosen.nil?

          payload = {
            id: "rss-media:#{MediaDigest.url_digest(chosen.url)[0, 16]}",
            type: 'embed',
            delivery: 'remote',
            url: chosen.url,
            position: candidate['position'],
            external: true,
          }
          payload[:duration] = candidate['duration'] if candidate['duration'].is_a?(Integer)
          payload[:description] = candidate['description'] if candidate['description'].present?
          preview = poster_preview
          payload[:poster] = preview if preview.present?
          payload
        end

        # Saved poster file on this instance. The publisher URL is not sent
        # to the browser, so showing the image does not request that host.
        def poster_preview
          image = Array(@resource.media_candidates).find { |row| row['kind'] == 'image' && row['role'] == 'poster' }
          attachment = image && link_for(image)&.media_attachment
          return nil if attachment.nil? || attachment.file_file_name.blank?

          full_asset_url(attachment.file.url(:original))
        rescue StandardError
          nil
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

        def link_for(candidate)
          urls = [candidate['url'], *Array(candidate['fallbacks'])]
          urls.each do |url|
            link = links[MediaDigest.url_digest(url)]
            return link if link
          end
          nil
        end

        def links
          @links ||= @projection.external_projection_attachments.includes(:external_media_asset).each_with_object({}) do |row, memo|
            GenerationMap.display_digests(row.external_media_asset).each do |digest|
              memo[digest] ||= row
            end
          end
        end
      end
    end
  end
end
