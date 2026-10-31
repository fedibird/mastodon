# frozen_string_literal: true

module ExternalBridge
  module RSS
    Response = Struct.new(:code, :body, :etag, :last_modified, :final_url, :content_type, :content_length, keyword_init: true)

    # Public GET through Request. Private addresses are rejected on every hop.
    # No Authorization header is ever attached.
    #
    # Redirects are followed here, not by HTTP.rb. HTTP.rb 5.2.0 calls
    # Response#flush before on_redirect, and flush reads the body with
    # Body#to_s, which is not subject to the feed byte caps. Closing the
    # redirect response without reading it keeps that body out of the
    # process. The next hop is a new Request for the canonical URL, so the
    # GET matches the stored key. Set-Cookie is not copied onto that hop:
    # this client never sends a cookie of its own.
    #
    # One response is capped on its own. Redirect bodies are not added in,
    # so three hops do not multiply the byte cap. Each hop opens a new
    # connection and uses the profile timeout or Request::TIMEOUT. Those
    # timeouts are not lengthened. The worst case is the original request
    # plus REDIRECT_HOPS connections, each with its own deadline.
    class HttpClient
      include Redisable

      # Matches the max_hops previously passed to HTTP.rb. The response that
      # would be the next hop after this many redirects is a failure, and
      # its Location is not requested.
      REDIRECT_HOPS = 3
      REDIRECT_STATUSES = [300, 301, 302, 303, 307, 308].freeze

      # How one kind of public GET differs from the feed fetch. Every profile
      # shares the same public-only rules: Request rejects private addresses on
      # every DNS answer, every redirect hop is normalized again, no credential
      # is sent, and the response is read through a byte limit.
      #
      # max_bytes is the inflated-body cap used by profiles that still read
      # through Request#body_with_limit (HTTP.rb auto_inflate). Feed fetches
      # do not use that path. max_received_bytes is the encoded body cap and
      # max_inflated_bytes is the inflated body cap, both in bytes. max_bytes
      # on the feed profile stays equal to the inflated cap.
      FetchProfile = Struct.new(
        :accept, :max_bytes, :asset_urls, :budget_namespace, :budget, :content_types,
        :truncate, :timeouts, :url_mode, :same_origin, :max_received_bytes, :max_inflated_bytes,
        keyword_init: true
      )

      FEED_PROFILE = FetchProfile.new(
        accept: 'application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1',
        max_bytes: Limits::MAX_RESPONSE_BYTES,
        max_received_bytes: Limits::MAX_RECEIVED_BYTES,
        max_inflated_bytes: Limits::MAX_RESPONSE_BYTES,
        asset_urls: false,
        budget_namespace: 'external_bridge:rss:host:',
        budget: Limits::HOST_BUDGET,
        # nil on purpose: application/xml and text/xml are normal for RSS 1.0,
        # and a Content-Type alone does not decide whether the body is a feed.
        content_types: nil,
        truncate: false,
        timeouts: nil,
        # Public selection parameters are accepted only on this profile.
        # NodeInfo, ActivityPub, icons, and media keep their own URL rules.
        url_mode: :feed
      ).freeze

      NODEINFO_PROFILE = FetchProfile.new(
        accept: 'application/json',
        max_bytes: 64.kilobytes,
        asset_urls: false,
        budget_namespace: 'external_bridge:rss_nodeinfo:host:',
        budget: 10,
        content_types: %w(application/json application/ld+json),
        truncate: false,
        timeouts: { connect_timeout: 5, read_timeout: 5, write_timeout: 5, read_deadline: 10 }.freeze,
        same_origin: true
      ).freeze

      ACTIVITYPUB_PROFILE = FetchProfile.new(
        accept: 'application/ld+json; profile="https://www.w3.org/ns/activitystreams", application/activity+json;q=0.9',
        max_bytes: 256.kilobytes,
        asset_urls: false,
        budget_namespace: 'external_bridge:rss_ap:host:',
        budget: 10,
        content_types: %w(application/activity+json application/ld+json),
        truncate: false,
        timeouts: { connect_timeout: 5, read_timeout: 5, write_timeout: 5, read_deadline: 10 }.freeze,
        url_mode: :item
      ).freeze

      ICON_IMAGE_PROFILE = FetchProfile.new(
        accept: 'image/png, image/webp, image/jpeg, image/gif, image/x-icon, image/vnd.microsoft.icon;q=0.9',
        max_bytes: Limits::ICON_MAX_BYTES,
        asset_urls: true,
        budget_namespace: 'external_bridge:rss_icon:host:',
        budget: Limits::ICON_HOST_BUDGET,
        content_types: nil,
        truncate: false,
        timeouts: Limits::ICON_TIMEOUTS
      ).freeze

      # Only the head of the page matters, so a long page is cut instead of
      # rejected.
      MEDIA_IMAGE_PROFILE = FetchProfile.new(
        accept: 'image/png, image/webp, image/jpeg, image/gif',
        max_bytes: Limits::MEDIA_IMAGE_MAX_BYTES,
        asset_urls: false,
        budget_namespace: 'external_bridge:rss_media:host:',
        budget: Limits::MEDIA_HOST_BUDGET,
        content_types: %w(image/png image/jpeg image/gif image/webp),
        truncate: false,
        timeouts: Limits::MEDIA_IMAGE_TIMEOUTS,
        url_mode: :media
      ).freeze

      # Signed poster URLs are image fetches. Video and ordinary images stay
      # on MediaURL and do not accept a rotating signature query.
      MEDIA_POSTER_PROFILE = MEDIA_IMAGE_PROFILE.dup.tap { |profile| profile.url_mode = :poster }.freeze

      ICON_PAGE_PROFILE = FetchProfile.new(
        accept: 'text/html, application/xhtml+xml;q=0.9',
        max_bytes: Limits::ICON_MAX_PAGE_BYTES,
        asset_urls: true,
        budget_namespace: 'external_bridge:rss_icon:host:',
        budget: Limits::ICON_HOST_BUDGET,
        content_types: %w(text/html application/xhtml+xml),
        truncate: true,
        timeouts: Limits::ICON_TIMEOUTS
      ).freeze

      def self.same_origin?(url, origin)
        left = Addressable::URI.parse(url.to_s)
        right = Addressable::URI.parse(origin.to_s)
        return false if left.host.blank? || right.host.blank?

        same_scheme = left.scheme.to_s.casecmp(right.scheme.to_s).zero?
        same_scheme && left.normalized_host == right.normalized_host && port_of(left) == port_of(right)
      rescue Addressable::URI::InvalidURIError
        false
      end

      def self.port_of(uri)
        uri.port || uri.default_port
      end

      def self.get(url, etag: nil, last_modified: nil, profile: FEED_PROFILE, origin: nil)
        new.get(url, etag: etag, last_modified: last_modified, profile: profile, origin: origin)
      end

      def self.head(url, profile: FEED_PROFILE, origin: nil)
        new.head(url, profile: profile, origin: origin)
      end

      def get(url, etag: nil, last_modified: nil, profile: FEED_PROFILE, origin: nil)
        with_fetch_errors do
          prepare_call(profile, origin, etag, last_modified)
          canonical = prepare_url!(url, profile, origin)
          consume_budget!(canonical, profile)
          follow(:get, canonical, REDIRECT_HOPS)
        end
      end

      # Headers only. A missing or unusable Content-Length means the size is
      # unknown. Callers must not fall through to a full GET just to measure.
      def head(url, profile: FEED_PROFILE, origin: nil)
        with_fetch_errors do
          prepare_call(profile, origin, nil, nil)
          canonical = prepare_url!(url, profile, origin)
          consume_budget!(canonical, profile)
          follow(:head, canonical, REDIRECT_HOPS)
        end
      end

      private

      def prepare_url!(url, profile, origin)
        raise ArgumentError, 'same-origin fetch requires an origin' if profile.same_origin && origin.blank?

        canonical = canonical_url!(url, profile)
        enforce_same_origin!(canonical, origin) if profile.same_origin
        canonical
      end

      def enforce_same_origin!(url, origin)
        raise Error, :cross_origin_redirect unless self.class.same_origin?(url, origin)
      end

      def canonical_url!(url, profile)
        return poster_canonical!(url) if profile.url_mode.to_s == 'poster'
        return MediaURL.normalize!(url) if profile.url_mode.to_s == 'media'
        return activitypub_canonical!(url) if profile.url_mode.to_s == 'item'
        return feed_canonical!(url) if profile.url_mode.to_s == 'feed'

        CanonicalURL.normalize!(url, asset: profile.asset_urls)
      end

      def feed_canonical!(url)
        CanonicalURL.normalize!(url, feed: true)
      end

      # Existing RSS item URLs may use a video viewkey. Such URLs are
      # intentionally not accepted for extra AP metadata requests.
      def activitypub_canonical!(url)
        normalized = CanonicalURL.normalize!(url, item: true)
        query = Addressable::URI.parse(normalized).query.to_s
        raise Error, :authenticated_source_rejected if query.split('&').any? { |pair| pair.start_with?('viewkey=') }

        normalized
      end

      def media_profile?(profile)
        %w(media poster).include?(profile.url_mode.to_s)
      end

      # A poster whose query is only a rotating signature is still an image
      # fetch. PosterURL keeps that signature on the request and does not
      # treat it as the file identity. Other media profiles never reach this.
      def poster_canonical!(url)
        MediaURL.normalize(url) || PosterURL.fetch!(url)
      end

      def host_validation_code(error)
        text = error.message.to_s
        return 'authenticated_source_rejected' if text.include?('authenticated_source_rejected')
        return 'unsupported_url' if text.include?('unsupported_url')
        return 'cross_origin_redirect' if text.include?('cross_origin_redirect')
        return 'rate_limited' if text.include?('rate_limited')

        'private_address'
      end

      def prepare_call(profile, origin, etag, last_modified)
        @profile = profile
        @origin = origin
        @etag = etag
        @last_modified = last_modified
        @visited = []
      end

      def with_fetch_errors
        yield
      rescue Mastodon::HostValidationError => e
        raise Error, host_validation_code(e)
      rescue Mastodon::LengthValidationError
        raise Error, media_profile?(@profile) ? :media_too_large : :oversized_feed
      rescue HTTP::Redirector::TooManyRedirectsError
        raise Error, :too_many_redirects
      rescue HTTP::Error, OpenSSL::SSL::SSLError, Addressable::URI::InvalidURIError
        raise Error, :fetch_failed
      end

      # follow: nil disables HTTP.rb's redirector, whose flush would read the
      # redirect body before our cap. A feed client also omits auto_inflate
      # so BodyReader sees the encoded bytes exactly once.
      def request_options
        options = { follow: nil }
        options[:timeout_options] = @profile.timeouts if @profile.timeouts
        options[:http_client] = HTTP::Client.new if feed_profile?
        options
      end

      def feed_profile?
        @profile.url_mode.to_s == 'feed'
      end

      def follow(verb, url, hops_left)
        redirect_to = nil
        result = nil
        perform_request(verb, url) do |response|
          if redirect_response?(response)
            raise Error, :too_many_redirects if hops_left <= 0 || @visited.include?(url)

            @visited << url
            redirect_to = accept_redirect!(response, url)
          else
            result = terminal_response(verb, response, url)
          end
        end
        return result if redirect_to.nil?

        follow(verb, redirect_to, hops_left - 1)
      end

      def perform_request(verb, url, &block)
        request = Request.new(verb, url, **request_options)
        # Request#initialize runs Addressable::URI#normalize, which decodes
        # reserved octets such as %2C. The canonical string is the GET target.
        request.instance_variable_set(:@url, Addressable::URI.parse(url))
        headers = verb == :head ? { 'Accept' => @profile.accept } : request_headers(@etag, @last_modified, @profile)
        request.add_headers(headers)
        request.perform(&block)
      end

      def redirect_response?(response)
        REDIRECT_STATUSES.include?(response.code.to_i)
      end

      # Canonicalize and charge the host budget before the next socket
      # exists. The redirect body is left unread; Request closes the
      # non-persistent client when this block returns.
      def accept_redirect!(response, current_url)
        canonical = canonical_url!(join_location(current_url, redirect_location(response)), @profile)
        enforce_same_origin!(canonical, @origin) if @profile.same_origin
        consume_budget!(canonical, @profile)
        canonical
      end

      def redirect_location(response)
        values = response.headers.get(HTTP::Headers::LOCATION)
        raise Error, :fetch_failed unless values.size == 1

        location = values.first.to_s
        raise Error, :fetch_failed if location.blank? || location.bytesize > Limits::MAX_KEY_BYTES

        location
      end

      def join_location(current_url, location)
        Addressable::URI.parse(current_url).join(location).to_s
      rescue Addressable::URI::InvalidURIError
        raise Error, :fetch_failed
      end

      def terminal_response(verb, response, url)
        return head_result(response, url) if verb == :head

        build_response(response, url, @profile)
      end

      def head_result(response, requested_url)
        length = response.content_length
        Response.new(
          code: response.code.to_i,
          body: nil,
          etag: nil,
          last_modified: nil,
          final_url: safe_final_url(response, requested_url, @profile),
          content_type: response.headers['Content-Type'].to_s.split(';').first.to_s.strip.downcase.presence,
          content_length: length.present? && length.positive? ? length.to_i : nil
        )
      end

      def request_headers(etag, last_modified, profile)
        headers = {
          'Accept' => profile.accept,
        }
        headers['If-None-Match'] = etag if etag.present?
        headers['If-Modified-Since'] = last_modified if last_modified.present?
        headers
      end

      def build_response(response, requested_url, profile)
        code = response.code.to_i
        final_url = safe_final_url(response, requested_url, profile)
        if code == 304
          return Response.new(code: 304, body: nil, etag: nil, last_modified: nil, final_url: final_url)
        end

        content_type = response.headers['Content-Type'].to_s.split(';').first.to_s.strip.downcase.presence
        body = code.between?(200, 299) && type_allowed?(content_type, profile) ? read_body(response, profile) : ''
        Response.new(
          code: code,
          body: body.to_s,
          etag: public_header(response, 'ETag'),
          last_modified: public_header(response, 'Last-Modified'),
          final_url: final_url,
          content_type: content_type
        )
      end

      def type_allowed?(content_type, profile)
        profile.content_types.nil? || profile.content_types.include?(content_type)
      end

      def read_body(response, profile)
        if profile.url_mode.to_s == 'feed'
          return BodyReader.read!(
            response,
            received_limit: profile.max_received_bytes,
            inflated_limit: profile.max_inflated_bytes
          )
        end
        return response.body_with_limit(profile.max_bytes) unless profile.truncate

        response.truncated_body(profile.max_bytes).to_s.b.byteslice(0, profile.max_bytes)
      end

      def safe_final_url(response, requested_url, profile)
        candidate = response.uri.to_s.presence || requested_url
        canonical_url!(candidate, profile)
      rescue Error
        raise Error, :authenticated_source_rejected
      end

      def public_header(response, name)
        value = response.headers[name].to_s
        return nil if value.blank? || value.bytesize > Limits::MAX_KEY_BYTES

        value
      end

      def consume_budget!(url, profile)
        host = Addressable::URI.parse(url).host.to_s.downcase
        key = "#{profile.budget_namespace}#{host}"
        count = nil
        with_redis do |redis|
          count = redis.incr(key)
          redis.expire(key, Limits::HOST_WINDOW) if count.to_i == 1
        end
        raise Error, :rate_limited if count.to_i > profile.budget
      end
    end
  end
end
