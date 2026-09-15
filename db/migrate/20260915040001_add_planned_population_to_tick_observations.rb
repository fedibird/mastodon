# frozen_string_literal: true

class AddPlannedPopulationToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # planned_* = selected simulation. executable_* remains the eligible
    # candidate population. Nullable: 0 = observed empty, NULL = not attempted.
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :planned_owner_count, :integer
      add_column :follow_import_dispatch_tick_observations, :planned_batch_count, :integer
    end
  end
end
