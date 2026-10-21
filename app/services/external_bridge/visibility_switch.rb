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

    def transition_ready?
      connection = ActiveRecord::Base.connection
      field = connection.select_value(<<~SQL)
        SELECT prosrc FROM pg_proc WHERE proname = 'statuses_external_projection_field_guard'
      SQL
      migrate = connection.select_value(<<~SQL)
        SELECT proname FROM pg_proc WHERE proname = 'external_visibility_migrate_status'
      SQL
      config = connection.select_value(<<~SQL)
        SELECT proconfig::text FROM pg_proc WHERE proname = 'external_visibility_migrate_status'
      SQL
      trigger = connection.select_value(<<~SQL)
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'statuses_external_projection_field_guard' AND NOT tgisinternal
      SQL
      field.to_s.include?('fedibird.external_visibility_migration') &&
        field.to_s.include?('to_jsonb(OLD)') &&
        migrate.present? &&
        config.to_s.include?('fedibird.external_visibility_migration') &&
        trigger.present? &&
        database_ready?
    end

    def assert_database_ready!
      return if database_ready?

      raise Error, :external_visibility_database_not_ready
    end
  end
end
