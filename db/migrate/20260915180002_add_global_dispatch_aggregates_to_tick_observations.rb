# frozen_string_literal: true

class AddGlobalDispatchAggregatesToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # GLOBAL-mode tick aggregates. Nullable: NULL = not applicable /
    # not attempted (shadow ticks, lease_busy, errors before planning).
    # 0 = observed empty / claimed nothing. Do not coerce NULL to 0.
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :global_base_budget, :integer
      add_column :follow_import_dispatch_tick_observations, :effective_global_budget, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_stale_count, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_unrecoverable_count, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_wrong_owner_count, :integer
    end
  end
end
