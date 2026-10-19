# frozen_string_literal: true

module ExternalBridge
  module RSS
    Response = Struct.new(:code, :body, :etag, :last_modified, :final_url, keyword_init: true)

    # Public GET through Request. Private addresses are rejected on every hop.
    # No Authorization header is ever attached.
    class HttpClient
      include Redisable

      def self.get(url, etag: nil, last_modified: nil)
        new.get(url, etag: etag, last_modified: last_modified)
      end

      def get(url, etag: nil, last_modified: nil)
        canonical = CanonicalURL.normalize!(url)
        consume_budget!(canonical)
        request = Request.new(:get, canonical, follow: redirect_policy)
        request.add_headers(request_headers(etag, last_modified))
        request.perform do |response|
          build_response(response, canonical)
        end
      rescue Mastodon::HostValidationError => e
        raise Error, (e.message.to_s.include?('authenticated_source_rejected') ? :authenticated_source_rejected : :private_address)
      rescue Mastodon::LengthValidationError
        raise Error, :oversized_feed
      rescue HTTP::Error, OpenSSL::SSL::SSLError, Addressable::URI::InvalidURIError
        raise Error, :fetch_failed
      end

      private

      # Reject the next hop before HTTP follows it. The socket check still
      # runs for DNS answers; this stops a private literal, userinfo, or
      # token-like query from being requested at all.
      def redirect_policy
        {
          max_hops: 3,
          on_redirect: lambda do |_response, next_request|
            CanonicalURL.normalize!(next_request.uri.to_s)
          rescue Error => e
            raise Mastodon::HostValidationError, e.code
          end,
        }
      end

      def request_headers(etag, last_modified)
        headers = {
          'Accept' => 'application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, */*;q=0.1',
        }
        headers['If-None-Match'] = etag if etag.present?
        headers['If-Modified-Since'] = last_modified if last_modified.present?
        headers
      end

      def build_response(response, requested_url)
        code = response.code.to_i
        final_url = safe_final_url(response, requested_url)
        if code == 304
          return Response.new(code: 304, body: nil, etag: nil, last_modified: nil, final_url: final_url)
        end

        body = code.between?(200, 299) ? response.body_with_limit(Limits::MAX_RESPONSE_BYTES) : ''
        Response.new(
          code: code,
          body: body.to_s,
          etag: public_header(response, 'ETag'),
          last_modified: public_header(response, 'Last-Modified'),
          final_url: final_url
        )
      end

      def safe_final_url(response, requested_url)
        candidate = response.uri.to_s.presence || requested_url
        CanonicalURL.normalize!(candidate)
      rescue Error
        raise Error, :authenticated_source_rejected
      end

      def public_header(response, name)
        value = response.headers[name].to_s
        return nil if value.blank? || value.bytesize > Limits::MAX_KEY_BYTES

        value
      end

      def consume_budget!(url)
        host = Addressable::URI.parse(url).host.to_s.downcase
        key = "external_bridge:rss:host:#{host}"
        count = nil
        with_redis do |redis|
          count = redis.incr(key)
          redis.expire(key, Limits::HOST_WINDOW) if count.to_i == 1
        end
        raise Error, :rate_limited if count.to_i > Limits::HOST_BUDGET
      end
    end
  end
end
