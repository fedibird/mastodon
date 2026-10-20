# frozen_string_literal: true

module Oauth
  module Bluesky
    class JwksController < ActionController::Base
      def show
        document = ExternalBridge::Atproto::ClientDocument.jwks
        return head :not_found if document.nil?

        expires_in 5.minutes, public: true
        render json: document
      end
    end
  end
end
