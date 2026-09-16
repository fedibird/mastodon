# frozen_string_literal: true

class AddAdaptiveRemoteShadowToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # PR G shadow adaptive remote-pacing aggregates. Nullable:
    # NULL = not evaluated / not applicable (shadow ticks, flag off,
    # invalid/unconfigured profile, GLOBAL zero-budget short-circuit).
    # 0 = evaluated and observed zero. Do not coerce NULL to 0.
    # Adaptive runtime state itself stays in Redis, not a durable table.
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :adaptive_remote_shadow_enabled, :boolean
      add_column :follow_import_dispatch_tick_observations, :adaptive_remote_configured, :boolean
      add_column :follow_import_dispatch_tick_observations, :adaptive_profile_version, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_shadow_evaluated_current_claim_count, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_shadow_would_block_current_claim_count, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_shadow_destination_would_block_count, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_shadow_origin_would_block_count, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_runtime_unavailable_count, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_destination_cap_min, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_destination_cap_max, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_origin_cap_min, :integer
      add_column :follow_import_dispatch_tick_observations, :adaptive_origin_cap_max, :integer
    end
  end
end
