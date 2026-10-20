# frozen_string_literal: true

module ExternalServices
  # AT Protocol connection cards. Reads identity columns only. It does not
  # decrypt the vault and it does not choose a token URL.
  module Bluesky
    KEY = 'bluesky'
    ICON = 'external_services/bluesky.svg'
    STATUSES = {
      'connected' => :connected,
      'warning' => :warning,
      'disconnected' => :disconnected,
      'reauthentication_required' => :reauthentication_required,
    }.freeze

    class Page
      attr_reader :identities, :enabled, :permitted, :configured

      def initialize(identities:, enabled:, permitted:, configured:)
        @identities = identities
        @enabled = enabled
        @permitted = permitted
        @configured = configured
      end

      def connectable?
        permitted && configured
      end
    end

    class << self
      def key
        KEY
      end

      def display_name
        I18n.t('external_services.providers.bluesky.name')
      end

      def icon
        ICON
      end

      def description
        I18n.t('external_services.providers.bluesky.description')
      end

      def available?
        ExternalBridge::Atproto::Feature.enabled? && ExternalBridge::Atproto::ClientDocument.configured?
      end

      def visible_to?(user)
        ExternalBridge::Atproto::Feature.permitted?(user)
      end

      def manage_path
        routes.settings_external_services_bluesky_path
      end

      def connections_for(user)
        identities_for(user).map { |identity| card_for(user, identity) }
      end

      def catalog_entry_for(user)
        rows = identities_for(user)
        connection = connections_for(user).first
        CatalogEntry.new(
          provider_key: key,
          title: display_name,
          description: description,
          icon: icon,
          configured: rows.any?,
          status: connection&.status,
          status_label: connection&.status_label,
          action: rows.any? ? :manage : :add,
          path: manage_path
        )
      end

      def page_for(user)
        Page.new(
          identities: identities_for(user),
          enabled: ExternalBridge::Atproto::Feature.enabled?,
          permitted: ExternalBridge::Atproto::Feature.permitted?(user),
          configured: ExternalBridge::Atproto::ClientDocument.configured?
        )
      end

      private

      def identities_for(user)
        return [] if user.nil?

        ExternalIdentity.where(user_id: user.id, provider: ExternalBridge::Atproto::Codes::PROVIDER).order(id: :desc).to_a
      end

      def card_for(user, identity)
        status = card_status(user, identity)
        Connection.new(
          provider_key: key,
          title: identity.handle.presence || identity.subject,
          subtitle: I18n.t('external_services.providers.bluesky.subtitle', issuer: identity.issuer),
          status: status,
          status_label: I18n.t("external_bridge.atproto.status.#{identity.status}"),
          last_used_at: identity.last_checked_at,
          manage_path: manage_path,
          icon: icon
        )
      end

      def card_status(user, identity)
        return :warning unless ExternalBridge::Atproto::Feature.permitted?(user) && ExternalBridge::Atproto::ClientDocument.configured?

        STATUSES.fetch(identity.status, :warning)
      end

      def routes
        Rails.application.routes.url_helpers
      end
    end
  end
end
