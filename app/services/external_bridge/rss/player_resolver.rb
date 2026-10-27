# frozen_string_literal: true

module ExternalBridge
  module RSS
    # Turns a player candidate into one https URL, or nothing.
    #
    # The feed's iframe HTML is never stored. A later provider can be added
    # in front of GenericProvider. The generic rule requires the same
    # registrable domain (Public Suffix List) and the same media id as the
    # article. A shared public suffix such as `com` is not a site. It rejects
    # the local instance, private hosts, credential URLs, direct media files,
    # and lookalike hosts. It does not accept an arbitrary iframe.
    class PlayerResolver
      Decision = Struct.new(:url, :origin, :provider, :at, keyword_init: true)
      PROVIDERS = %w(generic).freeze

      def self.choose(article_url, candidates)
        new(article_url, candidates).choose
      end

      def initialize(article_url, candidates)
        @article_url = article_url.to_s
        @candidates = Array(candidates)
      end

      def choose
        ordered = @candidates.sort_by { |row| [row[:priority].to_i, row[:at].to_i] }
        ordered.each do |row|
          Array(row[:urls]).first(Limits::MAX_EMBED_SCAN).each do |url|
            decision = GenericProvider.resolve(@article_url, url, row[:origin])
            next if decision.nil? || decision.url.blank?

            return Decision.new(url: decision.url, origin: decision.origin, provider: decision.provider, at: row[:at].to_i)
          end
        end
        nil
      end

      # Default host and path check. Explicit providers can replace this.
      class GenericProvider
        FILE_EXT = %w(.mp4 .webm .ogv .mov .m3u8 .mpd .mp3 .m4a .aac .ogg .oga .wav .flac .opus .jpg .jpeg .png .gif .webp .svg).freeze
        QUERY_NAMES = %w(id v video_id clip clip_id viewkey).freeze
        TOKEN = /\A[A-Za-z0-9_-]{4,80}\z/.freeze
        GENERIC = %w(watch embed player video view clip play media item article post posts entry).freeze
        LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/.freeze

        def self.resolve(article_url, player_url, origin)
          new(article_url, player_url, origin).resolve
        end

        def initialize(article_url, player_url, origin)
          @article_url = article_url.to_s
          @player_url = player_url.to_s
          @origin = origin.to_s
        end

        def resolve
          article = parse_article
          player = parse_player
          return nil if article.nil? || player.nil?
          return nil unless related?(article, player)
          return nil if (tokens(article) & tokens(player)).empty?

          url = canonical(player)
          return nil if url.blank?

          PlayerResolver::Decision.new(url: url, origin: @origin, provider: 'generic')
        end

        private

        def parse_article
          parse(@article_url, https_only: false)
        end

        def parse_player
          uri = parse(@player_url, https_only: true)
          return nil if uri.nil? || file_url?(uri) || instance_host?(uri.host) || !public_name?(uri.host)
          return nil if query_rejected?(uri)
          return nil if same_page?(uri)

          uri
        end

        def parse(value, https_only:)
          text = value.strip
          return nil if text.blank? || text.match?(/[\s\\<>"]/)
          return nil unless text.match?(/\Ahttps:/i) || (!https_only && text.match?(/\Ahttps?:/i))

          uri = Addressable::URI.parse(text)
          return nil if uri.nil? || uri.host.blank? || uri.user.present? || uri.password.present?
          return nil if unsafe_host?(uri.host)

          uri.scheme = uri.scheme.downcase
          uri.host = uri.host.downcase
          uri.port = nil if uri.port == uri.default_port
          uri.fragment = nil
          uri
        rescue Addressable::URI::InvalidURIError
          nil
        end

        def file_url?(uri)
          extension = File.extname(uri.path.to_s).downcase
          FILE_EXT.include?(extension)
        end

        def query_rejected?(uri)
          return false if uri.query.nil?
          return true if uri.query.blank?

          pairs = uri.query.split('&', -1)
          return true if pairs.size > 4

          pairs.any? do |pair|
            name, value = pair.split('=', 2)
            name.blank? || value.blank? || !QUERY_NAMES.include?(name.downcase) || !TOKEN.match?(value)
          end
        end

        def same_page?(player)
          article = parse(@article_url, https_only: false)
          return false if article.nil? || article.host != player.host

          path = player.path.to_s.split('/')
          path.none? { |segment| %w(embed player).include?(segment) }
        end

        # Registrable domain from the Public Suffix List. Two hosts that only
        # share a public suffix are different sites. A list failure rejects
        # the player instead of falling back to a hand-written suffix list.
        def related?(article, player)
          left = registrable_domain(article.host)
          right = registrable_domain(player.host)
          left.present? && left == right
        end

        def registrable_domain(host)
          name = host.to_s.downcase
          return nil if name.blank?

          PublicSuffix.domain(name)
        rescue PublicSuffix::Error
          nil
        end

        def tokens(uri)
          found = uri.path.to_s.split('/').filter_map { |segment| segment if token?(segment) }
          query_tokens(uri).each { |value| found << value }
          found.uniq
        end

        def query_tokens(uri)
          return [] if uri.query.blank?

          uri.query.split('&').filter_map do |pair|
            name, value = pair.split('=', 2)
            value if QUERY_NAMES.include?(name.to_s.downcase) && token?(value)
          end
        end

        def token?(value)
          TOKEN.match?(value.to_s) && !GENERIC.include?(value.to_s.downcase)
        end

        def public_name?(host)
          labels = host.to_s.split('.')
          return false if labels.size < 2

          labels.all? { |label| LABEL.match?(label) && !label.start_with?('xn--') }
        end

        def instance_host?(host)
          names = [
            Rails.configuration.x.web_domain,
            Rails.configuration.x.local_domain,
            *Array(Rails.configuration.x.alternate_domains),
          ]
          names.filter_map { |value| bare_host(value) }.any? { |item| host == item || host.end_with?(".#{item}") }
        end

        def bare_host(value)
          text = value.to_s.strip.sub(%r{\Ahttps?://}i, '').split('/').first.to_s
          text.split(':').first&.downcase.presence
        end

        def unsafe_host?(host)
          return true if MediaURL::LOCAL_HOST.match?(host.to_s)

          address = IPAddr.new(host)
          PrivateAddressCheck.private_address?(address)
        rescue IPAddr::InvalidAddressError
          false
        end

        def canonical(uri)
          text = uri.to_s
          return nil if text.bytesize > Limits::MAX_KEY_BYTES

          text
        end
      end
    end
  end
end
