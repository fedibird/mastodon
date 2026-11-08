# frozen_string_literal: true

# Public descriptions of interfaces whose availability depends on the
# OAuth application, viewer, or browser session. Never read user state here.
module Fedibird
  module CapabilityCatalog
    module Extensions
      module_function

      # Bluesky identity linking is a browser OAuth flow, not an AT Protocol
      # posting or timeline REST API provided by Fedibird.
      def integrations
        {
          bluesky_oauth: {
            scope: 'allowlisted_user',
            interface: 'browser_oauth',
            server_enabled: ExternalBridge::Atproto::Feature.enabled? == true,
            oauth_client_configured: ExternalBridge::Atproto::ClientDocument.configured? == true,
            settings_path: '/settings/external_services/bluesky',
          },
        }
      end

      # This is a capability description, never a user's permissions.
      # Notifications may be filtered by the OAuth application and user
      # preferences even when the notification type exists in the model.
      def contextual
        {
          notifications: {
            scope: 'viewer_and_client',
            collection_path: '/api/v1/notifications',
            supported_types: Notification::TYPES.map(&:to_s),
            filters: %w(types exclude_types account_id),
            conditional_fields: {
              reblog: %w(reblog_visibility),
              emoji_reaction: %w(emoji_reaction),
            },
          },
          preferences: {
            scope: 'authenticated_user',
            document_path: '/api/v1/fedibird/preferences',
            schema_path: '/api/v1/fedibird/preferences/schema',
            read_scopes_any: %w(read read:preferences),
            write_scope: 'write:preferences',
          },
          posting_identities: {
            scope: 'administrator',
            collection_path: '/api/v1/fedibird/posting_identities',
          },
        }
      end
    end
  end
end
