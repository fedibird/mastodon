# frozen_string_literal: true

class CreateFollowImportTransportObservations < ActiveRecord::Migration[6.1]
  def change
    # Observation-only transport telemetry. batch_id / target_id are nullable
    # correlation tokens, not foreign keys, so this table's lifetime is not
    # coupled to ModerationSubject / FollowImportBatch retention.
    create_table :follow_import_transport_observations do |t|
      t.bigint :batch_id
      t.bigint :target_id
      t.string :phase, null: false
      t.string :destination_domain
      t.string :endpoint_origin
      t.string :sidekiq_queue
      t.string :sidekiq_job_id
      t.datetime :started_at, null: false
      t.datetime :finished_at, null: false
      t.integer :duration_ms, null: false
      t.string :outcome, null: false
      t.integer :http_status
      t.integer :retry_after_seconds
      t.string :error_class
      t.jsonb :metadata, null: false, default: {}
      t.datetime :created_at, null: false
    end

    add_index :follow_import_transport_observations, :batch_id,
              name: :index_fi_transport_observations_on_batch_id
    add_index :follow_import_transport_observations, :target_id,
              name: :index_fi_transport_observations_on_target_id
    add_index :follow_import_transport_observations, [:phase, :destination_domain],
              name: :index_fi_transport_observations_on_phase_and_domain
    add_index :follow_import_transport_observations, [:phase, :endpoint_origin],
              name: :index_fi_transport_observations_on_phase_and_origin
  end
end
