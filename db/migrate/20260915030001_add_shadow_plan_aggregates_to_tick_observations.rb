# frozen_string_literal: true

class AddShadowPlanAggregatesToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # Aggregate shadow-plan facts. Nullable: 0 = planned/observed empty,
    # NULL = planning not attempted or measurement unavailable.
    # Does not store owner keys, target ids, or account handles.
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :planned_count, :integer
      add_column :follow_import_dispatch_tick_observations, :executable_owner_count, :integer
      add_column :follow_import_dispatch_tick_observations, :executable_batch_count, :integer
      add_column :follow_import_dispatch_tick_observations, :unique_destination_count, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_missing_owner_count, :integer
      add_column :follow_import_dispatch_tick_observations, :fairness_state_source, :string
    end
  end
end
