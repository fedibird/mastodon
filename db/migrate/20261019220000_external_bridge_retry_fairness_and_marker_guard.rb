# frozen_string_literal: true

# Bound per-item projection retries, and require a marker to point at a
# personal external projection. The stricter trigger stays in place on rollback.
class ExternalBridgeRetryFairnessAndMarkerGuard < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      add_column :external_projection_failures, :attempt_count, :integer, null: false, default: 0
      add_column :external_projection_failures, :next_attempt_at, :datetime
      execute ExternalBridge::Schema::DEFINITIONS_SQL
    end
  end

  def down
    safety_assured do
      remove_column :external_projection_failures, :next_attempt_at
      remove_column :external_projection_failures, :attempt_count
    end
  end
end
