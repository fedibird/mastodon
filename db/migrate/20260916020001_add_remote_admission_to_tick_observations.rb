# frozen_string_literal: true

class AddRemoteAdmissionToTickObservations < ActiveRecord::Migration[6.1]
  def change
    # PR F fixed remote-admission aggregates. Nullable: NULL = not
    # evaluated / not applicable (shadow ticks, enforcement off,
    # misconfigured profile, GLOBAL zero-budget short-circuit).
    # 0 = evaluated and observed zero. Do not coerce NULL to 0.
    safety_assured do
      add_column :follow_import_dispatch_tick_observations, :remote_admission_enabled, :boolean
      add_column :follow_import_dispatch_tick_observations, :remote_admission_configured, :boolean
      add_column :follow_import_dispatch_tick_observations, :remote_profile_version, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_destination_cap_count, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_origin_cap_count, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_unavailable_count, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_retry_after_count, :integer
      add_column :follow_import_dispatch_tick_observations, :skipped_recent_429_count, :integer
      add_column :follow_import_dispatch_tick_observations, :scanned_target_count, :integer
      add_column :follow_import_dispatch_tick_observations, :windows_scanned, :integer
      add_column :follow_import_dispatch_tick_observations, :scan_budget_exhausted_count, :integer
      add_column :follow_import_dispatch_tick_observations, :mapped_origin_candidate_count, :integer
    end
  end
end
