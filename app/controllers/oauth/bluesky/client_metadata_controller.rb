# frozen_string_literal: true

module Oauth
  module Bluesky
    class ClientMetadataController < ActionController::Base
      def show
        document = ExternalBridge::Atproto::ClientDocument.metadata
        return head :not_found if document.nil?

        expires_in 5.minutes, public: true
        render json: document
      end
    end
  end
end
