# frozen_string_literal: true

class AddCohortBacklogCountsToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # Scoped backlog measurements for tick schema 10. Nullable:
    # NULL = not measured (GLOBAL zero-budget, lease_busy, failure).
    # 0 = observed empty. Do not coerce NULL to 0.
    # global_pending_count / active_batch_count keep the all-universe
    # meaning; these columns split historical vs operational vs the
    # exact planning scope for this tick.
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :historical_pending_count, :integer
      add_column :follow_import_dispatch_tick_observations, :operational_pending_count, :integer
      add_column :follow_import_dispatch_tick_observations, :planning_pending_count, :integer
      add_column :follow_import_dispatch_tick_observations, :historical_active_batch_count, :integer
      add_column :follow_import_dispatch_tick_observations, :operational_active_batch_count, :integer
      add_column :follow_import_dispatch_tick_observations, :planning_active_batch_count, :integer
    end
  end
end
