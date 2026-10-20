# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # did:plc and did:web resolution. Other methods are discovery_rejected.
    class Did
      PLC_PATTERN = /\Adid:plc:[a-z2-7]{24}\z/
      WEB_PATTERN = /\Adid:web:[a-zA-Z0-9.%_-]+(?::[a-zA-Z0-9.%_-]+)*\z/

      def self.valid?(value)
        string = value.to_s
        PLC_PATTERN.match?(string) || WEB_PATTERN.match?(string)
      end

      def self.document!(did, dns:)
        new(dns).document!(did)
      end

      def initialize(dns)
        @dns = dns
      end

      def document!(did)
        raise Error, :discovery_rejected unless self.class.valid?(did)

        url = did.start_with?('did:plc:') ? plc_url(did) : web_url(did)
        result = Http.get!(url, dns: @dns, accept: 'application/json', redirects: :none)
        raise Error, :discovery_rejected unless result.code == 200 && result.json_type?

        document = result.json
        raise Error, :discovery_rejected unless document['id'].to_s == did

        document
      end

      def self.pds_origin!(document, did)
        service = pds_service(document, did)
        endpoint = service_endpoint(service)
        Origin.https_origin!(endpoint)
      end

      def self.pds_service(document, did)
        services = document['service']
        raise Error, :discovery_rejected unless services.is_a?(Array)

        service = services.find { |entry| pds?(entry, did) }
        raise Error, :discovery_rejected unless service

        service
      end

      def self.pds?(entry, did)
        return false unless entry.is_a?(Hash)

        id = entry['id'].to_s
        return false unless ['#atproto_pds', "#{did}#atproto_pds"].include?(id)

        types = entry['type'].is_a?(Array) ? entry['type'] : [entry['type']]
        types.include?('AtprotoPersonalDataServer')
      end

      def self.service_endpoint(service)
        endpoint = service['serviceEndpoint']
        raise Error, :discovery_rejected unless endpoint.is_a?(String)

        endpoint
      end

      def self.verified_handle(document, expected:)
        names = Array(document['alsoKnownAs']).filter_map do |value|
          name = value.to_s[/\Aat:\/\/([^\/?#]+)\z/i, 1]&.downcase
          name if Handle.syntax?(name.to_s)
        end
        return expected if expected && names.include?(expected)
        raise Error, :discovery_rejected if expected

        names.first
      end

      private

      def plc_url(did)
        directory = ENV['ATPROTO_PLC_DIRECTORY'].presence || 'https://plc.directory'
        "#{Origin.https_origin!(directory)}/#{did}"
      end

      def web_url(did)
        parts = did.delete_prefix('did:web:').split(':')
        raise Error, :discovery_rejected if parts.empty? || parts.any?(&:blank?)

        decoded = parts.map { |part| decode_segment(part) }
        host = decoded.first
        path = decoded.drop(1)
        raise Error, :discovery_rejected if host.blank? || host.include?('/') || host.include?('@') || host.end_with?(':443')
        raise Error, :discovery_rejected if path.any? { |segment| segment.blank? || segment == '.' || segment == '..' || segment.include?('/') }

        return "https://#{host}/.well-known/did.json" if path.empty?

        "https://#{host}/#{path.join('/')}/did.json"
      end

      def decode_segment(part)
        value = CGI.unescape(part)
        raise Error, :discovery_rejected if value.match?(/[[:cntrl:]]/) || value.include?('\\')

        value
      end
    end
  end
end
