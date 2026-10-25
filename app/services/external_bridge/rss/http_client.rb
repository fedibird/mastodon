# frozen_string_literal: true

module ExternalBridge
  module RSS
    Response = Struct.new(:code, :body, :etag, :last_modified, :final_url, :content_type, keyword_init: true)

    # Public GET through Request. Private addresses are rejected on every hop.
    # No Authorization header is ever attached.
    class HttpClient
      include Redisable

      # How one kind of public GET differs from the feed fetch. Every profile
      # shares the same public-only rules: Request rejects private addresses on
      # every DNS answer, every redirect hop is normalized again, no credential
      # is sent, and the response is read through a byte limit.
      FetchProfile = Struct.new(:accept, :max_bytes, :asset_urls, :budget_namespace, :budget, :content_types, :truncate, :timeouts, keyword_init: true)

      FEED_PROFILE = FetchProfile.new(
        accept: 'application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1',
        max_bytes: Limits::MAX_RESPONSE_BYTES,
        asset_urls: false,
        budget_namespace: 'external_bridge:rss:host:',
        budget: Limits::HOST_BUDGET,
        content_types: nil,
        truncate: false,
        timeouts: nil
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

      def self.get(url, etag: nil, last_modified: nil, profile: FEED_PROFILE)
        new.get(url, etag: etag, last_modified: last_modified, profile: profile)
      end

      def get(url, etag: nil, last_modified: nil, profile: FEED_PROFILE)
        canonical = CanonicalURL.normalize!(url, asset: profile.asset_urls)
        consume_budget!(canonical, profile)
        request = Request.new(:get, canonical, **request_options(profile))
        request.add_headers(request_headers(etag, last_modified, profile))
        request.perform do |response|
          build_response(response, canonical, profile)
        end
      rescue Mastodon::HostValidationError => e
        raise Error, (e.message.to_s.include?('authenticated_source_rejected') ? :authenticated_source_rejected : :private_address)
      rescue Mastodon::LengthValidationError
        raise Error, :oversized_feed
      rescue HTTP::Error, OpenSSL::SSL::SSLError, Addressable::URI::InvalidURIError
        raise Error, :fetch_failed
      end

      private

      def request_options(profile)
        options = { follow: redirect_policy(profile) }
        options[:timeout_options] = profile.timeouts if profile.timeouts
        options
      end

      # Reject the next hop before HTTP follows it. The socket check still
      # runs for DNS answers; this stops a private literal, userinfo, or
      # token-like query from being requested at all.
      def redirect_policy(profile)
        {
          max_hops: 3,
          on_redirect: lambda do |_response, next_request|
            CanonicalURL.normalize!(next_request.uri.to_s, asset: profile.asset_urls)
          rescue Error => e
            raise Mastodon::HostValidationError, e.code
          end,
        }
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
        return response.body_with_limit(profile.max_bytes) unless profile.truncate

        response.truncated_body(profile.max_bytes).to_s.b.byteslice(0, profile.max_bytes)
      end

      def safe_final_url(response, requested_url, profile)
        candidate = response.uri.to_s.presence || requested_url
        CanonicalURL.normalize!(candidate, asset: profile.asset_urls)
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
