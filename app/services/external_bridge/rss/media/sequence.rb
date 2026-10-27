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
          decorate_poster!(payload, candidate)
          payload
        end

        # A role=poster file is the embed player's saved image. Remote video
        # posters stay as poster_url text and are not downloaded. The hash is
        # copied only when this candidate names that saved image, so one
        # article's poster is not painted onto a different video.
        def poster_image_for(candidate)
          linked = linked_poster(candidate['poster_url'])
          return linked if linked
          return nil if candidate['poster_url'].present?
          return nil unless candidate['kind'] == 'embed'
          return nil unless poster_candidates.one? && embed_candidates.one?

          poster_candidates.first
        end

        def linked_poster(poster_url)
          return nil if poster_url.blank?

          poster_candidates.find { |row| poster_urls(row).include?(poster_url) }
        end

        def poster_urls(row)
          [row['url'], *Array(row['fallbacks'])]
        end

        def poster_candidates
          @poster_candidates ||= Array(@resource.media_candidates).select { |row| row['kind'] == 'image' && row['role'] == 'poster' }
        end

        def embed_candidates
          @embed_candidates ||= Array(@resource.media_candidates).select { |row| row['kind'] == 'embed' }
        end

        def decorate_poster!(payload, candidate)
          attachment = poster_attachment_for(candidate)
          return if attachment.nil?

          assign_local_poster!(payload, attachment) if candidate['kind'] == 'embed'
          assign_poster_hashes!(payload, attachment)
        end

        def poster_attachment_for(candidate)
          image = poster_image_for(candidate)
          return nil if image.nil?

          attachment = link_for(image)&.media_attachment
          return nil if attachment.nil? || attachment.file_file_name.blank?

          attachment
        end

        # Saved poster file on this instance. The publisher URL is not sent
        # to the browser, so showing the image does not request that host.
        def assign_local_poster!(payload, attachment)
          url = full_asset_url(attachment.file.url(:original))
          payload[:poster] = url if url.present?
        rescue StandardError
          nil
        end

        def assign_poster_hashes!(payload, attachment)
          thumbhash = hash_text(attachment.thumbhash)
          blurhash = hash_text(attachment.blurhash)
          payload[:poster_thumbhash] = thumbhash if thumbhash
          payload[:poster_blurhash] = blurhash if blurhash
        end

        def hash_text(value)
          text = value.to_s.strip
          return nil if text.blank? || text.bytesize > 100
          return nil if text.include?('://') || text.start_with?('/')

          text
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
          entry = {
            id: "rss-media:#{MediaDigest.url_digest(candidate['url'])[0, 16]}",
            type: candidate['kind'],
            delivery: 'remote',
            url: candidate['url'],
            position: candidate['position'],
            description: candidate['description'],
            mime_type: candidate['mime_hint'],
            external: true,
          }.compact
          decorate_poster!(entry, candidate)
          entry
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
          @links ||= @projection.external_projection_attachments.includes(:external_media_asset, :media_attachment).each_with_object({}) do |row, memo|
            GenerationMap.display_digests(row.external_media_asset).each do |digest|
              memo[digest] ||= row
            end
          end
        end
      end
    end
  end
end
