# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Public feed identifiers that are not global finite tokens.
    #
    # A name is accepted only on the scheme, host, port, and path of one
    # documented feed. The same name on any other URL rejects the whole
    # query. Companion keys that the document does not list are rejected
    # too; they are not stripped. Each redirect hop constructs its own
    # FeedQuery from that hop's URI, so a match on the first URL does not
    # travel with the client.
    #
    # Publisher text and the limits below are different. Where a document
    # does not fix a length or alphabet, the pattern is a Fedibird cap.
    class FeedQuery
      # Push topic:
      # https://www.youtube.com/xml/feeds/videos.xml?channel_id=CHANNEL_ID
      # https://developers.google.com/youtube/data/guides/push_notifications
      # The Analytics API says a channel id currently begins with "UC" and
      # that the format can change. It does not fix the length or the
      # alphabet. 24 bytes and [A-Za-z0-9_-] match the ids shown in the
      # current Data API channel guides; that is not an official grammar.
      YOUTUBE_HOST = 'www.youtube.com'
      YOUTUBE_PATH = '/xml/feeds/videos.xml'
      CHANNEL_ID = /\AUC[A-Za-z0-9_-]{22}\z/.freeze

      # https://www.flickr.com/services/feeds/photos_public.gne
      # https://www.flickr.com/services/feeds/docs/photos_public/
      # https://www.flickr.com/services/feeds/
      # `id` is documented as one user id. The URL guide's stable form is
      # the NSID ("the number with the '@' sign", digits then @N and digits).
      # Digit width and the two-digit suffix are not given as a maximum;
      # 1..20 digits and `@` + N/n + two digits are Fedibird caps. Case is
      # preserved. `tags` is a comma-separated list with no published
      # alphabet or count; each tag is an ASCII token of at most 64 bytes,
      # and at most 10 tags. `tagmode` and `lang` are the lists on the feeds
      # page. `tagmode` without `tags` is rejected here because the parameter
      # is specified only as the match mode for tags.
      FLICKR_HOST = 'www.flickr.com'
      FLICKR_PATH = '/services/feeds/photos_public.gne'
      NSID = /\A[0-9]{1,20}@[Nn][0-9]{2}\z/.freeze
      TAG = /\A[A-Za-z0-9_-]{1,64}\z/.freeze
      MAX_TAGS = 10
      TAGMODES = %w(all any).freeze
      LANGS = %w(de-de en-us es-us fr-fr it-it ko-kr pt-br zh-hk).freeze
      # XML feed tokens from the feeds page. php, json, csv, sql, yaml, cdf,
      # and the page's unbounded "more" are not feed documents this bridge
      # stores. atom_1, rss_091, rss_092, rss_100, and rdf are not global
      # format tokens; they exist only on this path. They are not rewritten
      # onto rss or atom.
      FLICKR_FORMATS = %w(rss_200 rss2 atom_1 atom rss_091 rss_092 rss rss_100 rdf rss_200_enc).freeze
      FLICKR_ONLY_FORMATS = %w(atom_1 rss_091 rss_092 rss_100 rdf).freeze
      FLICKR_KEYS = %w(id tags tagmode format lang).freeze
      IDENTIFIER_KEYS = %w(channel_id id tags tagmode lang).freeze

      def self.canonicalize(uri, name, value)
        new(uri).canonicalize(name, value)
      end

      def self.validate_combination!(uri, pairs)
        new(uri).validate_combination!(pairs)
      end

      def initialize(uri)
        @uri = uri
      end

      # nil lets CanonicalURL apply the global finite table. A host-scoped
      # name either returns its canonical pair or rejects the URL.
      def canonicalize(name, value)
        case name
        when 'channel_id'
          channel_id(value)
        when 'id'
          flickr_id(value)
        when 'tags'
          tags(value)
        when 'tagmode'
          enumerated(name, value, TAGMODES)
        when 'lang'
          enumerated(name, value, LANGS)
        when 'format'
          flickr_format(value)
        end
      end

      def validate_combination!(pairs)
        names = pairs.keys
        return if (names & IDENTIFIER_KEYS).empty? && !FLICKR_ONLY_FORMATS.include?(pairs['format'])
        return if names == ['channel_id'] && youtube?

        raise Error, :authenticated_source_rejected if names.include?('channel_id')
        raise Error, :authenticated_source_rejected unless flickr?
        raise Error, :authenticated_source_rejected unless (names - FLICKR_KEYS).empty?
        raise Error, :authenticated_source_rejected if names.include?('tagmode') && !names.include?('tags')
        raise Error, :authenticated_source_rejected if pairs['format'] && !FLICKR_FORMATS.include?(pairs['format'])
      end

      private

      def channel_id(value)
        raise Error, :authenticated_source_rejected unless youtube? && CHANNEL_ID.match?(value)

        "channel_id=#{value}"
      end

      def flickr_id(value)
        raise Error, :authenticated_source_rejected unless flickr? && NSID.match?(value)

        "id=#{encode(value)}"
      end

      def tags(value)
        raise Error, :authenticated_source_rejected unless flickr?

        parts = value.split(',', -1)
        raise Error, :authenticated_source_rejected if parts.empty? || parts.size > MAX_TAGS
        raise Error, :authenticated_source_rejected unless parts.all? { |part| tag?(part) }

        "tags=#{encode(parts.join(','))}"
      end

      def tag?(part)
        part.bytesize <= 64 && TAG.match?(part)
      end

      def enumerated(name, value, allowed)
        raise Error, :authenticated_source_rejected unless flickr?

        folded = value.downcase
        raise Error, :authenticated_source_rejected unless allowed.include?(folded)

        "#{name}=#{folded}"
      end

      def flickr_format(value)
        folded = value.downcase
        return nil unless FLICKR_ONLY_FORMATS.include?(folded)
        raise Error, :authenticated_source_rejected unless flickr?

        "format=#{folded}"
      end

      # Unreserved characters stay literal. Everything else, including `@`
      # and `,`, is percent-encoded so a decoded separator cannot become a
      # new pair when the canonical string is parsed again.
      def encode(value)
        encoded = Addressable::URI.encode_component(value, Addressable::URI::CharacterClasses::UNRESERVED)
        raise Error, :authenticated_source_rejected if encoded.match?(/[&;=+[:space:]#]/)

        encoded
      end

      def youtube?
        secure?(YOUTUBE_HOST, YOUTUBE_PATH)
      end

      def flickr?
        secure?(FLICKR_HOST, FLICKR_PATH)
      end

      def secure?(host, path)
        return false unless @uri.scheme.to_s.casecmp('https').zero?
        return false unless @uri.host.to_s.casecmp(host).zero?
        return false unless @uri.path == path

        @uri.port.nil? || @uri.port == @uri.default_port
      end
    end
  end
end
