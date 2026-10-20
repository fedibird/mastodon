# frozen_string_literal: true

module ExternalServices
  # AT Protocol connection cards. Reads identity columns only. It does not
  # decrypt the vault and it does not choose a token URL.
  module Bluesky
    KEY = 'bluesky'
    ICON = 'external_services/bluesky.svg'
    LIST_LIMIT = 50
    STATUSES = {
      'connected' => :connected,
      'warning' => :warning,
      'disconnected' => :disconnected,
      'reauthentication_required' => :reauthentication_required,
    }.freeze

    class Summary
      attr_reader :total, :connected, :warning, :disconnected, :reauth, :checked_at

      def initialize(attributes)
        @total = attributes.fetch(:total)
        @connected = attributes.fetch(:connected)
        @warning = attributes.fetch(:warning)
        @disconnected = attributes.fetch(:disconnected)
        @reauth = attributes.fetch(:reauth)
        @checked_at = attributes[:checked_at]
      end

      def self.empty
        new({ total: 0, connected: 0, warning: 0, disconnected: 0, reauth: 0, checked_at: nil })
      end

      def status
        return if total.zero?
        return :reauthentication_required if reauth.positive?
        return :warning if warning.positive?
        return :disconnected if disconnected == total
        return :connected if connected.positive?

        :warning
      end
    end

    class Page
      attr_reader :identities, :enabled, :permitted, :configured, :page, :total_count, :total_pages

      def initialize(attributes)
        @identities = attributes.fetch(:identities)
        @enabled = attributes.fetch(:enabled)
        @permitted = attributes.fetch(:permitted)
        @configured = attributes.fetch(:configured)
        @page = attributes.fetch(:page)
        @total_count = attributes.fetch(:total_count)
        @total_pages = attributes.fetch(:total_pages)
      end

      def connectable?
        permitted && configured
      end

      def blocked_reason
        return I18n.t('external_bridge.atproto.disabled') unless enabled
        return I18n.t('external_bridge.atproto.tester_only') unless permitted
        return I18n.t('external_bridge.atproto.errors.signing_key_unavailable') unless configured

        nil
      end
    end

    # Display fields for one owned identity. Token material is not copied here.
    class IdentityRow
      def initialize(identity)
        @identity = identity
      end

      def id
        @identity.id
      end

      def handle
        @identity.handle.to_s
      end

      def subject
        @identity.subject.to_s
      end

      def display_name
        handle.presence || subject.presence || I18n.t('external_bridge.atproto.no_handle')
      end

      def reconnect_identifier
        handle.presence || subject
      end

      def status
        @identity.status
      end

      def status_label
        I18n.t("external_bridge.atproto.status.#{@identity.status}")
      end

      def badge
        STATUSES.fetch(@identity.status, :warning).to_s
      end

      def last_checked_at
        @identity.last_checked_at
      end

      def issuer
        @identity.issuer.to_s
      end

      def resource_origin
        @identity.resource_origin.to_s
      end

      def scopes_label
        scopes = Array(@identity.granted_scopes).map(&:to_s).reject(&:blank?)
        return I18n.t('external_bridge.atproto.no_scopes') if scopes.empty?

        scopes.join(', ')
      end

      def error_message
        code = @identity.last_error_code
        return if code.blank?

        I18n.t("external_bridge.atproto.errors.#{code}", default: I18n.t('external_bridge.atproto.errors.authorization_failed'))
      end

      def revocation_label
        state = @identity.revocation_state
        return if state.blank?

        I18n.t("external_bridge.atproto.revocation.#{state}", default: I18n.t('external_bridge.atproto.errors.authorization_failed'))
      end

      def disconnected?
        @identity.disconnected_at.present? || @identity.status == 'disconnected'
      end

      def reauthentication_required?
        !disconnected? && @identity.status == 'reauthentication_required'
      end

      def checkable?
        !disconnected? && !reauthentication_required?
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

      # Permitted testers can open the page when the signing key is missing.
      # The catalog gate still requires visible_to?.
      def listed_when_unconfigured?
        true
      end

      def visible_to?(user)
        ExternalBridge::Atproto::Feature.permitted?(user)
      end

      def manage_path
        routes.settings_external_services_bluesky_path
      end

      def connections_for(user)
        summary = summary_for(user)
        return [] if summary.total.zero?

        [card_for(summary)]
      end

      def catalog_entry_for(user)
        summary = summary_for(user)
        configured = summary.total.positive?
        connectable = ExternalBridge::Atproto::Feature.permitted?(user) && ExternalBridge::Atproto::ClientDocument.configured?
        status = if configured
                   summary.status
                 elsif !ExternalBridge::Atproto::ClientDocument.configured?
                   :unavailable
                 end
        CatalogEntry.new(
          provider_key: key,
          title: display_name,
          description: description,
          detail: (count_label(summary) if configured),
          icon: icon,
          configured: configured,
          status: status,
          status_label: catalog_status_label(status),
          action: configured ? :manage : :add,
          action_label: catalog_action_label(configured, connectable),
          path: manage_path
        )
      end

      def page_for(user, page: 1)
        summary = summary_for(user)
        number = clamp_page(page, summary.total)
        rows = identity_scope(user).order(id: :desc).offset((number - 1) * LIST_LIMIT).limit(LIST_LIMIT).to_a
        attributes = {
          identities: rows.map { |row| IdentityRow.new(row) },
          enabled: ExternalBridge::Atproto::Feature.enabled?,
          permitted: ExternalBridge::Atproto::Feature.permitted?(user),
          configured: ExternalBridge::Atproto::ClientDocument.configured?,
          page: number,
          total_count: summary.total,
          total_pages: page_count(summary.total),
        }
        Page.new(attributes)
      end

      private

      def card_for(summary)
        Connection.new(
          provider_key: key,
          title: display_name,
          lead: description,
          subtitle: count_label(summary),
          status: summary.status,
          status_label: catalog_status_label(summary.status),
          last_used_at: summary.checked_at,
          shows_check_time: true,
          manage_label: I18n.t('external_services.actions.bluesky.manage'),
          manage_path: manage_path,
          icon: icon
        )
      end

      def summary_for(user)
        return Summary.empty if user.nil?

        total, connected, warning, disconnected, reauth, checked_at = identity_scope(user).pick(
          Arel.sql('COUNT(*)'),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'connected')"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'warning')"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'disconnected')"),
          Arel.sql("COUNT(*) FILTER (WHERE status = 'reauthentication_required')"),
          Arel.sql('MAX(last_checked_at)')
        )
        summary = {
          total: total.to_i,
          connected: connected.to_i,
          warning: warning.to_i,
          disconnected: disconnected.to_i,
          reauth: reauth.to_i,
          checked_at: coerce_time(checked_at),
        }
        Summary.new(summary)
      end

      def count_label(summary)
        I18n.t(
          'external_services.providers.bluesky.subtitle',
          count: summary.total,
          connected: summary.connected,
          reauth: summary.reauth,
          disconnected: summary.disconnected
        )
      end

      def catalog_action_label(configured, connectable)
        return I18n.t('external_services.actions.bluesky.manage') if configured
        return I18n.t('external_services.actions.bluesky.add') if connectable

        I18n.t('external_services.actions.bluesky.unavailable')
      end

      def catalog_status_label(status)
        return if status.nil?

        case status
        when :connected then I18n.t('external_bridge.atproto.status.connected')
        when :warning then I18n.t('external_bridge.atproto.status.warning')
        when :disconnected then I18n.t('external_bridge.atproto.status.disconnected')
        when :reauthentication_required then I18n.t('external_bridge.atproto.status.reauthentication_required')
        else I18n.t('external_services.status.unavailable')
        end
      end

      def identity_scope(user)
        return ExternalIdentity.none if user.nil?

        ExternalIdentity.where(user_id: user.id, provider: ExternalBridge::Atproto::Codes::PROVIDER)
      end

      def clamp_page(page, total)
        number = page.to_i
        number = 1 if number < 1
        number = 10_000 if number > 10_000
        pages = page_count(total)
        return 1 if pages.zero?
        return pages if number > pages

        number
      end

      def page_count(total)
        return 0 if total.zero?

        (total.to_f / LIST_LIMIT).ceil
      end

      def coerce_time(value)
        case value
        when nil then nil
        when Time, ActiveSupport::TimeWithZone then value
        else Time.zone.parse(value.to_s)
        end
      end

      def routes
        Rails.application.routes.url_helpers
      end
    end
  end
end
