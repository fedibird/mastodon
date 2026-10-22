# frozen_string_literal: true

module ExternalBridge
  # Storage-format switch for new projections. Off keeps ProjectionWriter on
  # personal. On writes external. It does not rewrite existing rows and it is
  # not a user preference or an RSS/AT Protocol feature flag.
  module VisibilitySwitch
    module_function

    def enabled?
      ActiveModel::Type::Boolean.new.cast(Setting.external_bridge_external_visibility)
    end

    # E1 installed the shape guard and taught the marker trigger to accept 201.
    # Inserts of an external projection need that. The 200-to-201 permit is a
    # separate check used by the operator command.
    def database_ready?
      connection = ActiveRecord::Base.connection
      shape = connection.select_value(<<~SQL)
        SELECT 1 FROM pg_proc WHERE proname = 'statuses_external_visibility_shape_guard'
      SQL
      marker = connection.select_value(<<~SQL)
        SELECT prosrc FROM pg_proc WHERE proname = 'external_status_projections_enforce_owner_account'
      SQL
      shape.present? && marker.to_s.include?('NOT IN (200, 201)')
    end

    # The migrate function must save and restore the caller's GUC itself.
    # proconfig must not store that custom parameter: CREATE FUNCTION SET
    # on a custom GUC is rejected for a normal database owner.
    def transition_ready?
      connection = ActiveRecord::Base.connection
      field = connection.select_value(<<~SQL)
        SELECT prosrc FROM pg_proc WHERE proname = 'statuses_external_projection_field_guard'
      SQL
      migrate = connection.select_value(<<~SQL)
        SELECT prosrc FROM pg_proc WHERE proname = 'external_visibility_migrate_status'
      SQL
      config = connection.select_value(<<~SQL)
        SELECT proconfig::text FROM pg_proc WHERE proname = 'external_visibility_migrate_status'
      SQL
      trigger = connection.select_value(<<~SQL)
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'statuses_external_projection_field_guard' AND NOT tgisinternal
      SQL
      body = migrate.to_s
      field.to_s.include?('fedibird.external_visibility_migration') &&
        field.to_s.include?('to_jsonb(OLD)') &&
        body.include?("previous := current_setting('fedibird.external_visibility_migration', true)") &&
        body.include?("set_config('fedibird.external_visibility_migration', token, true)") &&
        body.include?("set_config('fedibird.external_visibility_migration', previous, true)") &&
        body.include?('query_canceled') &&
        body.include?('WHEN OTHERS') &&
        !config.to_s.include?('fedibird.external_visibility_migration') &&
        trigger.present? &&
        database_ready?
    end

    def assert_database_ready!
      return if database_ready?

      raise Error, :external_visibility_database_not_ready
    end
  end
end
