# frozen_string_literal: true

class RefineFollowImportPacingTelemetry < ActiveRecord::Migration[6.1]
  def up
    # Transport: keep worker started_at/finished_at/duration_ms, and add the
    # enqueue + actual-HTTP timestamps so queue wait and remote request time
    # can be distinguished. Unknown timings stay NULL, never 0.
    safety_assured do
      add_column :follow_import_transport_observations, :enqueued_at, :datetime
      add_column :follow_import_transport_observations, :request_started_at, :datetime
      add_column :follow_import_transport_observations, :request_finished_at, :datetime
      add_column :follow_import_transport_observations, :queue_wait_ms, :integer
      add_column :follow_import_transport_observations, :request_duration_ms, :integer

      add_column :follow_import_dispatch_observations, :batch_pending_before, :integer
      add_column :follow_import_dispatch_observations, :batch_pending_after, :integer
      add_column :follow_import_dispatch_observations, :global_pending_count, :integer
      add_column :follow_import_dispatch_observations, :active_batch_count, :integer

      change_column_null :follow_import_dispatch_observations, :pending_count, true
      change_column_default :follow_import_dispatch_observations, :pending_count, from: 0, to: nil
      change_column_null :follow_import_dispatch_observations, :load_snapshot, true
      change_column_default :follow_import_dispatch_observations, :load_snapshot, from: {}, to: nil

      remove_index :follow_import_transport_observations,
                   name: :index_fi_transport_observations_on_phase_and_domain
      remove_index :follow_import_transport_observations,
                   name: :index_fi_transport_observations_on_phase_and_origin

      add_index :follow_import_transport_observations, :started_at,
                name: :index_fi_transport_observations_on_started_at
      add_index :follow_import_transport_observations, [:phase, :destination_domain, :started_at],
                name: :index_fi_transport_observations_on_phase_domain_started
      add_index :follow_import_transport_observations, [:phase, :endpoint_origin, :started_at],
                name: :index_fi_transport_observations_on_phase_origin_started
      add_index :follow_import_dispatch_observations, :observed_at,
                name: :index_fi_dispatch_observations_on_observed_at
    end
  end

  def down
    safety_assured do
      remove_index :follow_import_dispatch_observations,
                   name: :index_fi_dispatch_observations_on_observed_at
      remove_index :follow_import_transport_observations,
                   name: :index_fi_transport_observations_on_phase_origin_started
      remove_index :follow_import_transport_observations,
                   name: :index_fi_transport_observations_on_phase_domain_started
      remove_index :follow_import_transport_observations,
                   name: :index_fi_transport_observations_on_started_at

      add_index :follow_import_transport_observations, [:phase, :destination_domain],
                name: :index_fi_transport_observations_on_phase_and_domain
      add_index :follow_import_transport_observations, [:phase, :endpoint_origin],
                name: :index_fi_transport_observations_on_phase_and_origin

      change_column_default :follow_import_dispatch_observations, :load_snapshot, from: nil, to: {}
      change_column_null :follow_import_dispatch_observations, :load_snapshot, false
      change_column_default :follow_import_dispatch_observations, :pending_count, from: nil, to: 0
      change_column_null :follow_import_dispatch_observations, :pending_count, false

      remove_column :follow_import_dispatch_observations, :active_batch_count
      remove_column :follow_import_dispatch_observations, :global_pending_count
      remove_column :follow_import_dispatch_observations, :batch_pending_after
      remove_column :follow_import_dispatch_observations, :batch_pending_before

      remove_column :follow_import_transport_observations, :request_duration_ms
      remove_column :follow_import_transport_observations, :queue_wait_ms
      remove_column :follow_import_transport_observations, :request_finished_at
      remove_column :follow_import_transport_observations, :request_started_at
      remove_column :follow_import_transport_observations, :enqueued_at
    end
  end
end
