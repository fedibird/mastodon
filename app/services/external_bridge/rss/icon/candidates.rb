# frozen_string_literal: true

module ExternalBridge
  module RSS
    module Icon
      # Where to look for a feed's icon, best candidate first. The list is
      # lazy: the site page is fetched only if no feed-declared image worked,
      # and /favicon.ico only after that.
      #
      #   1. Images the feed itself declares (Atom icon, RSS image, Atom logo),
      #      resolved against the feed URL. The feed owner chose these, so a
      #      CDN host is fine.
      #   2. `<link rel="icon">` and `apple-touch-icon` of the site page, the
      #      larger declared size first.
      #   3. /favicon.ico of that same site.
      #
      # Steps 2 and 3 use the feed's own site. A `<link>` in a feed can name any
      # host, so a site URL on a different registrable domain than the feed is
      # ignored and the feed's own origin is used instead; one feed can never
      # borrow another site's favicon.
      class Candidates
        Candidate = Struct.new(:url, :origin, keyword_init: true)

        HTML_ICON_RELS = %w(icon apple-touch-icon apple-touch-icon-precomposed).freeze

        def initialize(source)
          @source = source
        end

        def each
          return enum_for(:each) unless block_given?

          seen = {}
          emit = lambda do |candidate|
            next if candidate.nil? || seen[candidate.url]

            seen[candidate.url] = true
            yield candidate
          end

          declared.each(&emit)
          html_candidates.each(&emit)
          emit.call(favicon)
        end

        def site_origin
          @site_origin ||= begin
            uri = Addressable::URI.parse(trusted_site_url)
            "#{uri.scheme}://#{uri.authority}"
          end
        end

        def trusted_site_url
          @trusted_site_url ||= begin
            site = normalize(@source.site_url, asset: false)
            site && same_site?(site, @source.canonical_key) ? site : origin_url(@source.canonical_key)
          end
        end

        private

        def declared
          Array(@source.icon_hints).filter_map do |hint|
            next unless hint.is_a?(Hash)

            url = resolve(hint['url'], @source.canonical_key)
            Candidate.new(url: url, origin: hint['kind'].to_s) if url
          end
        end

        def html_candidates
          page = fetch_page
          return [] if page.nil?

          document = Nokogiri::HTML(page.body)
          links = document.css('link[href]').filter_map { |node| html_link(node, page.final_url) }
          links.each_with_index.sort_by { |(link, index)| [-link[:size], index] }.map do |(link, _)|
            Candidate.new(url: link[:url], origin: link[:origin])
          end
        rescue Error
          []
        end

        def fetch_page
          response = HttpClient.get(trusted_site_url, profile: HttpClient::ICON_PAGE_PROFILE)
          response.code.between?(200, 299) && response.body.present? ? response : nil
        end

        def html_link(node, base)
          rels = node['rel'].to_s.downcase.split
          kind = (rels & HTML_ICON_RELS).first
          return nil if kind.nil? || rels.include?('mask-icon')
          return nil if node['type'].to_s.downcase.include?('svg')

          url = resolve(node['href'], base)
          return nil if url.nil? || Addressable::URI.parse(url).path.to_s.downcase.end_with?('.svg')

          { url: url, origin: kind == 'icon' ? 'html_icon' : 'html_apple_touch', size: declared_size(node['sizes']) }
        end

        # "32x32 64x64" -> 64. "any" and a missing value are 0.
        def declared_size(value)
          value.to_s.downcase.scan(/(\d+)x(\d+)/).map { |w, h| [w.to_i, h.to_i].min }.max.to_i
        end

        def favicon
          url = resolve('/favicon.ico', "#{site_origin}/")
          Candidate.new(url: url, origin: 'favicon') if url
        end

        def resolve(value, base)
          text = value.to_s.strip
          return nil if text.empty? || text.bytesize > Limits::MAX_KEY_BYTES

          normalize(Addressable::URI.parse(base).join(text).to_s, asset: true)
        rescue Addressable::URI::InvalidURIError
          nil
        end

        def normalize(value, asset:)
          return nil if value.blank?

          CanonicalURL.normalize!(value, asset: asset)
        rescue Error
          nil
        end

        def origin_url(url)
          uri = Addressable::URI.parse(url)
          "#{uri.scheme}://#{uri.authority}"
        end

        def same_site?(left, right)
          registrable(Addressable::URI.parse(left).host) == registrable(Addressable::URI.parse(right).host)
        end

        def registrable(host)
          host = host.to_s.downcase
          PublicSuffix.domain(host) || host
        rescue PublicSuffix::Error
          host
        end
      end
    end
  end
end
