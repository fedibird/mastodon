# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Binds Media RSS thumbnails to the media object that actually owns them.
    #
    # Optional metadata applies from the inside out: content, then group, then
    # item. Channel-level metadata is not copied onto items. A thumbnail nested
    # in media:content is already that content's poster and never reaches this
    # class as its own candidate.
    #
    # One thumbnail in a scope is the poster of every video in that scope that
    # does not already have a nearer poster. It is not paired with videos by
    # document order. Further thumbnails in the same scope stay image
    # attachments. A thumbnail is removed from the gallery only when it was
    # used as a video poster.
    #
    # A thumbnail whose scope contains audio and no video is audio artwork.
    # Phase 1 still leaves it as an image attachment, with usage and
    # subject_url for a later display connection. Several audios, or a scope
    # that also contains video, do not receive that label.
    class MediaScope
      # An explicit article image keeps its attachment row even when a poster
      # uses the same normalized URL. A Media RSS thumbnail does not.
      INDEPENDENT_ORIGINS = %w(html_img html_picture media_rss enclosure).freeze
      SKIP_USAGES = %w(author decoration).freeze

      def self.apply!(raw)
        new(raw).apply!
      end

      def self.skipped?(candidate)
        SKIP_USAGES.include?(candidate['usage'].to_s)
      end

      def initialize(raw)
        @raw = raw
      end

      def apply!
        assign_posters!
        mark_audio_art!
        @raw
      end

      private

      def assign_posters!
        videos.each do |video|
          next if video['poster_url'].present?

          thumb = nearest_group_thumbnail(video) || item_thumbnail_for(video)
          next if thumb.nil?

          video['poster_url'] = thumb['url']
          thumb['_consumed'] = true
        end
      end

      def nearest_group_thumbnail(video)
        Array(video['_group_path']).reverse_each do |group_id|
          found = group_thumbnail(group_id)
          return found if found
        end
        nil
      end

      def item_thumbnail_for(video)
        return nil if covered_by_group_thumbnail?(video)

        item_thumbnails.first
      end

      def covered_by_group_thumbnail?(video)
        Array(video['_group_path']).any? { |group_id| group_thumbnail(group_id) }
      end

      def group_thumbnail(group_id)
        group_thumbs[group_id]
      end

      def group_thumbs
        @group_thumbs ||= thumbnails.each_with_object({}) do |thumb, memo|
          next unless thumb['_scope'] == 'group' && thumb['_group_id']

          memo[thumb['_group_id']] ||= thumb
        end
      end

      def item_thumbnails
        @item_thumbnails ||= thumbnails.select { |thumb| thumb['_scope'] == 'item' }
      end

      def mark_audio_art!
        thumbnails.each do |thumb|
          next if thumb['_consumed']
          next if videos_in_scope(thumb).any?

          scoped = audios_in_scope(thumb)
          next unless scoped.one?

          thumb['usage'] = 'audio_art'
          thumb['subject_url'] = scoped.first['url']
        end
      end

      def videos_in_scope(thumb)
        return videos if thumb['_scope'] == 'item'

        gid = thumb['_group_id']
        videos.select { |video| Array(video['_group_path']).include?(gid) }
      end

      def audios_in_scope(thumb)
        return audios if thumb['_scope'] == 'item'

        gid = thumb['_group_id']
        audios.select { |audio| Array(audio['_group_path']).include?(gid) }
      end

      def thumbnails
        @thumbnails ||= @raw.select { |candidate| candidate['origin'] == 'media_thumbnail' && candidate['kind'] == 'image' }
      end

      def videos
        @videos ||= @raw.select { |candidate| candidate['kind'] == 'video' }
      end

      def audios
        @audios ||= @raw.select { |candidate| candidate['kind'] == 'audio' }
      end
    end
  end
end
