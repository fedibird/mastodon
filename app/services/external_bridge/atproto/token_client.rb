# frozen_string_literal: true

module ExternalBridge
  module Atproto
    # PAR, token, and revocation POSTs. The URL has to be the metadata
    # endpoint on the bound issuer. Redirects are not followed.
    class TokenClient
      def self.post!(url:, issuer:, fields:, dpop_key:, nonce:, dns:, timeout_code:, failure_code:, signing: nil) # rubocop:disable Metrics/ParameterLists -- token request stays named
        raise Error, :issuer_mismatch unless Origin.endpoint_origin(url) == issuer

        response = once(url, issuer, fields, dpop_key, nonce, dns, timeout_code, signing)
        if nonce_required?(response)
          nonce = response.header('dpop-nonce')
          raise Error, failure_code if nonce.blank?

          response = once(url, issuer, fields, dpop_key, nonce, dns, timeout_code, signing)
        end
        raise Error, failure_code unless response.code.between?(200, 299)
        raise Error, failure_code if response.header('dpop-nonce').blank? || !response.json_type?

        { 'json' => response.json, 'nonce' => response.header('dpop-nonce') }
      end

      def self.authorization_redirect(endpoint:, issuer:, request_uri:)
        raise Error, :issuer_mismatch unless Origin.endpoint_origin(endpoint) == issuer
        raise Error, :authorization_rejected if request_uri.blank? || request_uri.bytesize > 1024 || request_uri.match?(/[[:space:][:cntrl:]]/)

        uri = Addressable::URI.parse(endpoint)
        uri.query_values = { 'client_id' => ClientDocument.client_id, 'request_uri' => request_uri }
        uri.to_s
      end

      def self.once(url, issuer, fields, dpop_key, nonce, dns, timeout_code, signing) # rubocop:disable Metrics/ParameterLists -- one proof stays explicit
        form = fields.merge(
          'client_assertion_type' => Proofs::ASSERTION_TYPE,
          'client_assertion' => assertion(signing, issuer)
        )
        headers = { 'DPoP' => Proofs.dpop(key: dpop_key, htm: 'POST', url: url, nonce: nonce) }
        Http.post_form!(url, form, headers: headers, dns: dns, timeout_code: timeout_code)
      end

      def self.assertion(signing, issuer)
        return Proofs.client_assertion_for(signing, issuer: issuer) if signing

        Proofs.client_assertion(issuer: issuer)
      end

      def self.nonce_required?(response)
        return false unless response.code == 400

        parsed = JSON.parse(response.body.to_s)
        parsed.is_a?(Hash) && parsed['error'] == 'use_dpop_nonce'
      rescue JSON::ParserError
        false
      end

      private_class_method :once, :assertion, :nonce_required?
    end
  end
end
