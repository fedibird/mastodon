# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Kind of one Media RSS content. MIME and medium stay separate.
    #
    # An explicit audio MIME is audio even when medium says video, the file
    # ends in .mp4, and height is 0. An explicit video MIME with medium
    # audio, or with height 0, is deferred: it is not a normal video and it
    # is not guessed to be audio. Height omitted is not height 0.
    #
    # document, executable, SVG, and any other explicit type outside the
    # playback allow-list are rejected. Medium and the file extension do not
    # bring those back. When MIME is missing, medium and extension are used
    # only if they do not contradict each other. .mp4 alone is video, and it
    # does not contradict an explicit audio or video medium.
    class MediaClassifier
      VIDEO_MIME = %w(video/mp4 video/webm video/ogg video/quicktime).freeze
      HLS_MIME = %w(application/vnd.apple.mpegurl application/x-mpegurl).freeze
      AUDIO_EXT = %w(.mp3 .m4a .aac .ogg .oga .wav .flac .opus).freeze
      VIDEO_EXT = %w(.webm .ogv .mov .m3u8).freeze
      AMBIGUOUS_EXT = %w(.mp4).freeze
      IMAGE_EXT = %w(.jpg .jpeg .png .gif .webp).freeze
      REJECT_EXT = %w(.svg .pdf .exe .html .htm .js .zip).freeze
      REJECT_MEDIUMS = %w(document executable).freeze
      PLAYABLE_MEDIUMS = %w(image audio video).freeze
      MAX_DIMENSION = 100_000
      MAX_BITRATE = 100_000_000
      Result = Struct.new(:status, :kind, :mime, :medium, :width, :height, :bitrate, keyword_init: true)

      def self.decide(type:, medium:, url:, measures: {})
        new(type, medium, url, measures).decide
      end

      # True only for the token true. The string "false" is false, not true.
      # Anything else is ignored so a broken default cannot win.
      def self.flag(value)
        return nil if value.nil?

        token = value.to_s.strip
        return nil if token.empty?
        return true if token.casecmp('true').zero?
        return false if token.casecmp('false').zero?

        nil
      end

      # Blank means the Media RSS default, full. An unknown token is "other"
      # so it does not take the full tier. Callers persist only the real names.
      def self.expression(value)
        return nil if value.nil?

        token = value.to_s.strip.downcase
        return nil if token.empty?
        return token if %w(full sample nonstop).include?(token)

        'other'
      end

      def initialize(type, medium, url, measures)
        @type = type
        @medium_raw = medium
        @url = url
        @width_raw = measures[:width]
        @height_raw = measures[:height]
        @bitrate_raw = measures[:bitrate]
      end

      def decide
        mime, medium = tokens
        width = dimension(@width_raw)
        height = dimension(@height_raw)
        status, kind = classify(mime, medium, height)
        Result.new(
          status: status,
          kind: kind,
          mime: MediaLocator.mime_hint(mime),
          medium: PLAYABLE_MEDIUMS.include?(medium) ? medium : nil,
          width: stored_number(width),
          height: stored_number(height),
          bitrate: bitrate_number
        )
      end

      private

      def tokens
        type = @type.to_s.split(';').first.to_s.strip.downcase
        medium = @medium_raw.to_s.strip.downcase
        medium = nil if medium.empty?
        return [type, medium] if type.include?('/')

        medium ||= type if PLAYABLE_MEDIUMS.include?(type)
        [nil, medium]
      end

      def classify(mime, medium, height)
        return [:reject, nil] if REJECT_MEDIUMS.include?(medium)
        return [:reject, nil] if rejected_extension?
        return classify_mime(mime, medium, height) if mime.present?

        classify_loose(medium, height)
      end

      def classify_mime(mime, medium, height)
        return [:reject, nil] if %w(image/svg+xml audio/x-unknown).include?(mime)
        return image_kind(medium) if mime.start_with?('image/')
        return [:eligible, 'audio'] if mime.start_with?('audio/')
        return video_kind(medium, height) if video_mime?(mime)

        [:reject, nil]
      end

      def image_kind(medium)
        return [:deferred, nil] if %w(audio video).include?(medium)

        [:eligible, 'image']
      end

      def video_kind(medium, height)
        return [:deferred, nil] if medium == 'audio' || height&.zero?

        [:eligible, 'video']
      end

      def classify_loose(medium, height)
        ext = extension_kind
        return [:reject, nil] if ext == 'reject'
        return loose_without_medium(ext, height) if medium.nil?
        return [:reject, nil] unless PLAYABLE_MEDIUMS.include?(medium)
        return [:deferred, nil] if ext == 'image' && medium != 'image'
        return [:deferred, nil] if ext == 'audio' && medium != 'audio'
        return [:deferred, nil] if ext == 'video' && medium != 'video'
        return [:deferred, nil] if ext == 'ambiguous' && medium == 'image'
        return video_kind(medium, height) if medium == 'video'

        [:eligible, medium]
      end

      def loose_without_medium(ext, height)
        return [:reject, nil] if ext.nil?
        return video_kind('video', height) if %w(ambiguous video).include?(ext)

        [:eligible, ext]
      end

      def video_mime?(mime)
        VIDEO_MIME.include?(mime) || HLS_MIME.include?(mime)
      end

      def rejected_extension?
        REJECT_EXT.include?(extension)
      end

      def extension_kind
        return 'reject' if rejected_extension?
        return 'ambiguous' if AMBIGUOUS_EXT.include?(extension)
        return 'image' if IMAGE_EXT.include?(extension)
        return 'video' if VIDEO_EXT.include?(extension)
        return 'audio' if AUDIO_EXT.include?(extension)

        nil
      end

      def extension
        File.extname(Addressable::URI.parse(@url.to_s).path.to_s).downcase
      rescue Addressable::URI::InvalidURIError
        ''
      end

      # Missing and blank are omitted. Zero stays zero. Negative values and
      # values past the sanity cap are omitted, not treated as zero.
      def dimension(value)
        return nil if value.nil? || value.to_s.strip.empty?
        return nil unless value.to_s.strip.match?(/\A-?\d+\z/)

        number = Integer(value.to_s, 10)
        return nil if number.negative? || number > MAX_DIMENSION

        number
      end

      def stored_number(number)
        number.is_a?(Integer) ? number : nil
      end

      def bitrate_number
        return nil if @bitrate_raw.nil? || @bitrate_raw.to_s.strip.empty?
        return nil unless @bitrate_raw.to_s.strip.match?(/\A\d+\z/)

        number = Integer(@bitrate_raw.to_s, 10)
        return nil unless number.positive? && number <= MAX_BITRATE

        number
      end
    end
  end
end
