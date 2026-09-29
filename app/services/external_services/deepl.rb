# frozen_string_literal: true

module ExternalServices
  # Presentation for the personal DeepL connection.
  #
  # DeepL is one logical connection. Duplicate credential rows stay one card
  # and are repaired on the provider page. This module reads safe columns
  # only. It does not decrypt.
  module DeepL
    KEY = 'deepl'
    ICON = 'external_services/deepl.svg'
    SAFE_COLUMNS = %i(id created_at updated_at last_used_at revoked_at expires_at).freeze

    class Record
      def initialize(row)
        @row = row
      end

      def id
        @row.id
      end

      def created_at
        @row.created_at
      end

      def updated_at
        @row.updated_at
      end

      def last_used_at
        @row.last_used_at
      end

      def revoked?
        @row.revoked_at.present?
      end

      def expired?
        @row.expires_at.present? && @row.expires_at <= Time.current
      end
    end

    class Page
      attr_reader :records, :vault_available, :status, :status_label

      def initialize(records:, vault_available:, status:, status_label:)
        @records = records
        @vault_available = vault_available
        @status = status
        @status_label = status_label
      end

      def many?
        records.size > 1
      end

      def show_form?
        vault_available && !many?
      end
    end

    class << self
      def key
        KEY
      end

      def display_name
        I18n.t('external_services.providers.deepl.name')
      end

      def icon
        ICON
      end

      def description
        I18n.t('external_services.providers.deepl.description')
      end

      def available?
        true
      end

      def manage_path
        routes.settings_external_services_deepl_path
      end

      def connections_for(user)
        rows = safe_rows(user)
        return [] if rows.empty?

        status = status_for(rows)
        [card_for(rows, status)]
      end

      def catalog_entry_for(user)
        connection = connections_for(user).first
        status = connection&.status
        status ||= :unavailable unless UserCredentialVault.available?

        CatalogEntry.new(
          provider_key: key,
          title: display_name,
          description: description,
          icon: icon,
          status: status,
          status_label: status && status_label(status),
          action: connection ? :manage : :add,
          path: manage_path
        )
      end

      def page_for(user)
        rows = safe_rows(user)
        status = rows.empty? ? nil : status_for(rows)

        Page.new(
          records: rows.map { |row| Record.new(row) },
          vault_available: UserCredentialVault.available?,
          status: status,
          status_label: status && status_label(status)
        )
      end

      private

      def card_for(rows, status)
        Connection.new(
          provider_key: key,
          title: display_name,
          subtitle: I18n.t('external_services.providers.deepl.subtitle'),
          status: status,
          status_label: status_label(status),
          last_used_at: rows.map(&:last_used_at).compact.max,
          manage_path: manage_path,
          icon: icon
        )
      end

      def status_for(rows)
        return :unavailable unless UserCredentialVault.available?
        return :warning if rows.size > 1

        row = rows.first
        return :warning if row.revoked_at.present?
        return :warning if row.expires_at.present? && row.expires_at <= Time.current

        :connected
      end

      def status_label(status)
        I18n.t("external_services.status.#{status}")
      end

      def safe_rows(user)
        DeepLCredentialSettings.scope_for(user).select(*SAFE_COLUMNS).order(:id).to_a
      end

      def routes
        Rails.application.routes.url_helpers
      end
    end
  end
end
