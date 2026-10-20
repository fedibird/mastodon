# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Hardened GET and form POST. Metadata and token calls do not follow
    # redirects. Discovery redirects are revalidated and never carry DPoP,
    # Authorization, or a token body.
    class Http
      BODY_LIMIT = 256.kilobytes
      Result = Struct.new(:code, :body, :headers, keyword_init: true) do
        def header(name)
          value = headers[name.to_s.downcase]
          value.is_a?(Array) ? value.first.to_s : value.to_s
        end

        def json_type?
          header('content-type').downcase.start_with?('application/json')
        end

        def json
          parsed = JSON.parse(body.to_s)
          raise Error, :discovery_rejected unless parsed.is_a?(Hash)

          parsed
        rescue JSON::ParserError
          raise Error, :discovery_rejected
        end
      end

      class << self
        def get!(url, dns:, accept:, redirects:)
          current = Destination.check!(url, dns: dns)
          hops = 0
          loop do
            result = execute(:get, current, nil, { 'Accept' => accept }, :discovery_rejected)
            return result unless result.code.between?(300, 399)
            raise Error, :redirect_rejected if redirects == :none || hops >= 2

            current = Destination.check!(absolutize(result.header('location'), current), dns: dns)
            hops += 1
          end
        end

        def post_form!(url, form, headers:, dns:, timeout_code:)
          target = Destination.check!(url, dns: dns)
          result = execute(:post, target, URI.encode_www_form(form), headers.merge('Content-Type' => 'application/x-www-form-urlencoded'), timeout_code)
          raise Error, :redirect_rejected if result.code.between?(300, 399)

          result
        end

        private

        def execute(verb, url, body, headers, timeout_code)
          reject_sensitive_redirect_headers!(headers) if verb == :get
          request = Request.new(verb, url, **request_options(body))
          request.add_headers(headers)
          request.perform do |response|
            Result.new(code: response.code.to_i, body: read_body(response), headers: copy_headers(response))
          end
        rescue Mastodon::PrivateNetworkAddressError, Mastodon::HostValidationError
          raise Error, :private_address
        rescue Mastodon::LengthValidationError
          raise Error, :discovery_rejected
        rescue HTTP::TimeoutError, HTTP::ConnectionError, HTTP::Error, OpenSSL::SSL::SSLError
          raise Error, timeout_code
        end

        def request_options(body)
          # HTTP.rb treats max_hops 0 as unlimited. false disables its
          # redirector so this client can inspect the 3xx before any next hop.
          options = { follow: false }
          options[:body] = body if body
          options
        end

        def read_body(response)
          return '' unless response.code.to_i.between?(200, 499)

          response.body_with_limit(BODY_LIMIT).to_s
        end

        def copy_headers(response)
          mapped = {}
          response.headers.each { |key, value| mapped[key.to_s.downcase] = value }
          mapped
        rescue StandardError
          {}
        end

        def absolutize(location, current)
          raise Error, :redirect_rejected if location.blank?

          Addressable::URI.join(current, location).to_s
        rescue Addressable::URI::InvalidURIError
          raise Error, :redirect_rejected
        end

        def reject_sensitive_redirect_headers!(headers)
          raise Error, :authorization_failed if headers.keys.any? { |key| key.to_s.casecmp('authorization').zero? || key.to_s.casecmp('dpop').zero? }
        end
      end
    end
  end
end
