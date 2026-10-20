# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # DNS TXT then HTTPS well-known. A DNS failure does not fall through.
    # An empty TXT record may fall through to HTTPS. A published DID wins.
    class Handle
      LABEL = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
      DID_RECORD = /\Adid=((?:did:plc:[a-z2-7]{24})|(?:did:web:[A-Za-z0-9.%:-]+))\z/

      def self.syntax?(value)
        new(nil).syntax?(value)
      end

      def self.resolve(handle, dns:)
        new(dns).resolve(handle)
      end

      def initialize(dns)
        @dns = dns
      end

      def syntax?(value)
        handle = value.to_s
        return false if handle.bytesize > 253 || handle.count('.') < 1

        labels = handle.split('.')
        return false unless labels.all? { |label| LABEL.match?(label) }
        return false if labels.last.match?(/\A[0-9]/)

        true
      end

      def resolve(handle)
        normalized = handle.to_s.downcase
        raise Error, :discovery_rejected unless syntax?(normalized)

        from_dns = dns_did(normalized)
        return from_dns if from_dns

        http_did(normalized)
      end

      private

      def dns_did(handle)
        records = Array(@dns.txt("_atproto.#{handle}"))
        candidates = records.filter_map { |text| text.to_s.strip[DID_RECORD, 1] }
        return nil if candidates.empty?
        raise Error, :discovery_rejected unless candidates.uniq.size == 1 && Did.valid?(candidates.first)

        candidates.first
      end

      def http_did(handle)
        result = Http.get!("https://#{handle}/.well-known/atproto-did", dns: @dns, accept: 'text/plain', redirects: :limited)
        return nil if result.code == 404
        raise Error, :discovery_rejected unless result.code == 200

        body = result.body.to_s.strip
        raise Error, :discovery_rejected unless Did.valid?(body) && !result.json_type?

        body
      end
    end
  end
end
