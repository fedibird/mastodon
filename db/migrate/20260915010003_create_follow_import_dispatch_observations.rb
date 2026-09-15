# frozen_string_literal: true

class CreateFollowImportDispatchObservations < ActiveRecord::Migration[6.1]
  def change
    # One row per BatchExecutionWorker pass. Observation only: never used to
    # skip or slow dispatch. batch_id is a nullable correlation token, not an FK.
    create_table :follow_import_dispatch_observations do |t|
      t.bigint :batch_id
      t.datetime :observed_at, null: false
      t.integer :candidate_count, null: false, default: 0
      t.integer :claimed_count, null: false, default: 0
      t.integer :pending_count, null: false, default: 0
      t.jsonb :load_snapshot, null: false, default: {}
      t.jsonb :execution_policy, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :follow_import_dispatch_observations, [:batch_id, :observed_at],
              name: :index_fi_dispatch_observations_on_batch_and_observed_at
  end
end
