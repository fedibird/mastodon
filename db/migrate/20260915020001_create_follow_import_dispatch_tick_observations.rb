# frozen_string_literal: true

class CreateFollowImportDispatchTickObservations < ActiveRecord::Migration[6.1]
  def change
    # One row per global FollowImport::DispatchScheduler tick. Observation
    # only: never used to skip, slow, or claim work. claimed_count is 0 in
    # PR A shadow mode. Count columns are nullable (0 = observed empty,
    # NULL = measurement unavailable).
    create_table :follow_import_dispatch_tick_observations do |t|
      t.datetime :observed_at, null: false
      t.string :tick_id, null: false
      t.string :scheduler_mode, null: false
      t.boolean :lease_acquired, null: false
      t.string :outcome, null: false
      t.integer :global_pending_count
      t.integer :active_batch_count
      t.integer :claimed_count, null: false, default: 0
      t.jsonb :load_snapshot
      t.jsonb :execution_config
      t.string :error_class
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :follow_import_dispatch_tick_observations, :observed_at,
              name: :index_fi_dispatch_tick_observations_on_observed_at
    add_index :follow_import_dispatch_tick_observations, :tick_id,
              name: :index_fi_dispatch_tick_observations_on_tick_id
  end
end
