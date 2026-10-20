# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # Handle, DID, or hostname in. Bound issuer and PDS out. No token is sent.
    class Discovery
      Result = Struct.new(
        :input_kind,
        :login_hint,
        :did,
        :handle,
        :resource_origin,
        :issuer,
        :authorization_endpoint,
        :token_endpoint,
        :par_endpoint,
        :revocation_endpoint,
        :scopes_supported,
        keyword_init: true
      )

      def self.call(identifier, dns:)
        new(dns).call(identifier)
      end

      def self.confirm!(did:, issuer:, dns:)
        new(dns).confirm!(did, issuer)
      end

      def initialize(dns)
        @dns = dns
      end

      def call(identifier)
        kind, value = classify(identifier)
        case kind
        when :hostname then from_hostname(value)
        when :ambiguous then from_ambiguous(value)
        else from_did(value)
        end
      end

      def confirm!(did, issuer)
        document = Did.document!(did, dns: @dns)
        origin = Did.pds_origin!(document, did)
        bound = ServerMetadata.protected_issuer!(origin, dns: @dns)
        raise Error, :issuer_mismatch unless bound == issuer

        handle = display_handle(document, did)
        { resource_origin: origin, handle: handle }
      end

      private

      def classify(identifier)
        value = identifier.to_s.strip
        raise Error, :account_required if value.blank?
        raise Error, :discovery_rejected if value.bytesize > 512 || value.match?(/[[:cntrl:]]/)
        return [:did, value] if value.start_with?('did:')
        return [:hostname, Origin.https_origin!(value)] if value.include?('://')
        raise Error, :discovery_rejected if value.include?('/')
        raise Error, :discovery_rejected unless Handle.syntax?(value.downcase)

        [:ambiguous, value.downcase]
      end

      def from_ambiguous(handle)
        did = Handle.resolve(handle, dns: @dns)
        return from_hostname(Origin.https_origin!("https://#{handle}")) if did.nil?

        bind_account(did, handle, 'handle')
      end

      def from_did(did)
        raise Error, :discovery_rejected unless Did.valid?(did)

        bind_account(did, did, 'did')
      end

      def bind_account(did, login_hint, kind)
        document = Did.document!(did, dns: @dns)
        handle = kind == 'handle' ? Did.verified_handle(document, expected: login_hint) : display_handle(document, did)
        origin = Did.pds_origin!(document, did)
        issuer = ServerMetadata.protected_issuer!(origin, dns: @dns)
        raise Error, :discovery_rejected if issuer.nil?

        result_for(metadata_for(issuer), did: did, handle: handle, resource_origin: origin, kind: kind, login_hint: login_hint)
      end

      def from_hostname(origin)
        issuer = ServerMetadata.protected_issuer!(origin, dns: @dns)
        resource_origin = issuer ? origin : nil
        issuer ||= origin
        result_for(metadata_for(issuer), did: nil, handle: nil, resource_origin: resource_origin, kind: 'hostname', login_hint: nil)
      end

      def metadata_for(issuer)
        ServerMetadata.fetch!(issuer, dns: @dns)
      end

      def display_handle(document, did)
        candidate = Did.verified_handle(document, expected: nil)
        return nil if candidate.nil?

        Handle.resolve(candidate, dns: @dns) == did ? candidate : nil
      rescue Error
        nil
      end

      def result_for(metadata, did:, handle:, resource_origin:, kind:, login_hint:) # rubocop:disable Metrics/ParameterLists -- discovery result fields stay named
        Result.new(
          input_kind: kind,
          login_hint: login_hint,
          did: did,
          handle: handle,
          resource_origin: resource_origin,
          issuer: metadata.issuer,
          authorization_endpoint: metadata.authorization_endpoint,
          token_endpoint: metadata.token_endpoint,
          par_endpoint: metadata.par_endpoint,
          revocation_endpoint: metadata.revocation_endpoint,
          scopes_supported: metadata.scopes_supported
        )
      end
    end
  end
end
