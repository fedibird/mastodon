# frozen_string_literal: true

class AddLocalLoadEnforcementToDispatchObservations < ActiveRecord::Migration[6.1]
  def change
    # Legacy BatchExecutionWorker local-load enforcement facts. Nullable:
    # NULL = not evaluated / unavailable, 0/false = computed. Do not
    # default these to "normal" or rewrite historical rows.
    safety_assured do
      add_column :follow_import_dispatch_observations, :local_load_enforcement_enabled, :boolean
      add_column :follow_import_dispatch_observations, :local_load_state, :string
      add_column :follow_import_dispatch_observations, :local_load_budget_percent, :integer
      add_column :follow_import_dispatch_observations, :local_load_recommended_budget, :integer
      add_column :follow_import_dispatch_observations, :effective_execution_budget, :integer
      add_column :follow_import_dispatch_observations, :local_load_would_skip, :boolean
      add_column :follow_import_dispatch_observations, :local_load_measurement_complete, :boolean
      add_column :follow_import_dispatch_observations, :local_load_profile_version, :integer
      add_column :follow_import_dispatch_observations, :local_load_profile_source, :string
      add_column :follow_import_dispatch_observations, :local_load_fallback_used, :boolean
      add_column :follow_import_dispatch_observations, :load_deferred, :boolean
      add_column :follow_import_dispatch_observations, :local_load_decision, :jsonb
    end
  end
end
