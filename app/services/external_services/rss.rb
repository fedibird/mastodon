# frozen_string_literal: true

module ExternalServices
  # Public RSS/Atom subscriptions. No credential is read or stored.
  module RSS
    KEY = 'rss'
    ICON = 'external_services/rss.svg'

    class Page
      attr_reader :subscriptions, :items, :enabled, :permitted

      def initialize(subscriptions:, items:, enabled:, permitted:)
        @subscriptions = subscriptions
        @items = items
        @enabled = enabled
        @permitted = permitted
      end
    end

    class << self
      def key
        KEY
      end

      def display_name
        I18n.t('external_services.providers.rss.name')
      end

      def icon
        ICON
      end

      def description
        I18n.t('external_services.providers.rss.description')
      end

      def available?
        ExternalBridge::Feature.enabled?
      end

      def visible_to?(user)
        ExternalBridge::Feature.permitted?(user)
      end

      def manage_path
        routes.settings_external_services_rss_path
      end

      def connections_for(user)
        rows = subscriptions_for(user)
        return [] if rows.empty?

        status = card_status(user, rows)
        [card_for(rows, status)]
      end

      def catalog_entry_for(user)
        connection = connections_for(user).first
        CatalogEntry.new(
          provider_key: key,
          title: display_name,
          description: description,
          icon: icon,
          configured: !connection.nil?,
          status: connection&.status,
          status_label: connection&.status_label,
          action: connection ? :manage : :add,
          path: manage_path
        )
      end

      def page_for(user)
        rows = subscriptions_for(user)
        Page.new(
          subscriptions: rows,
          items: items_for(user),
          enabled: available?,
          permitted: ExternalBridge::Feature.permitted?(user)
        )
      end

      private

      def subscriptions_for(user)
        return [] if user.nil?

        ExternalSubscription.where(user_id: user.id).includes(:external_source).order(id: :desc).to_a
      end

      def items_for(user)
        ExternalStatusProjection.where(user_id: user.id)
                                .includes(:status, external_resource: :external_source)
                                .order(id: :desc)
                                .limit(40)
                                .to_a
      end

      def card_for(rows, status)
        Connection.new(
          provider_key: key,
          title: display_name,
          subtitle: I18n.t('external_services.providers.rss.subtitle', count: rows.size),
          status: status,
          status_label: I18n.t("external_services.status.#{status}"),
          last_used_at: rows.map(&:checked_at).compact.max,
          manage_path: manage_path,
          icon: icon
        )
      end

      def card_status(user, rows)
        return :unavailable unless ExternalBridge::Feature.permitted?(user)
        return :warning if rows.any? { |row| row.state == 'error' || row.failed_item_count.to_i.positive? || row.last_error_code.present? }

        :connected
      end

      def routes
        Rails.application.routes.url_helpers
      end
    end
  end
end
