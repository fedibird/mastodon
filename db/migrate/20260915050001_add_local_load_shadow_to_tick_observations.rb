# frozen_string_literal: true

class AddLocalLoadShadowToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # Shadow LocalLoadGuard facts. Nullable: NULL = not evaluated /
    # unusable, 0/false = computed. Do not default these to "normal".
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :local_load_state, :string
      add_column :follow_import_dispatch_tick_observations, :local_load_budget_percent, :integer
      add_column :follow_import_dispatch_tick_observations, :local_load_recommended_budget, :integer
      add_column :follow_import_dispatch_tick_observations, :effective_shadow_plan_budget, :integer
      add_column :follow_import_dispatch_tick_observations, :local_load_would_skip, :boolean
      add_column :follow_import_dispatch_tick_observations, :local_load_measurement_complete, :boolean
      add_column :follow_import_dispatch_tick_observations, :local_load_profile_version, :integer
      add_column :follow_import_dispatch_tick_observations, :local_load_profile_source, :string
    end
  end
end
