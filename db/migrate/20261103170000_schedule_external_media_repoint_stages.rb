# frozen_string_literal: true

# A sweep that always retries the oldest expired stages never reaches a later
# row when those oldest rows cannot be deleted. available_at and state let a
# failure step aside. The stage row stays: retained is not a delete.
class ScheduleExternalMediaRepointStages < ActiveRecord::Migration[6.1]
  def up
    safety_assured do
      execute "SET lock_timeout = '5s'"
      add_column :external_media_repoint_stages, :state, :string, null: false, default: 'pending', limit: 16
      add_column :external_media_repoint_stages, :available_at, :datetime, null: false, precision: 6, default: -> { 'CURRENT_TIMESTAMP' }
      add_column :external_media_repoint_stages, :attempt_count, :integer, null: false, default: 0
      add_column :external_media_repoint_stages, :failure_code, :string, limit: 64
      add_column :external_media_repoint_stages, :claim_token, :string, limit: 32
      add_column :external_media_repoint_stages, :claimed_until, :datetime, precision: 6
      execute <<~SQL.squish
        UPDATE external_media_repoint_stages
        SET available_at = lease_until
      SQL
      add_check_constraint :external_media_repoint_stages,
                           "state IN ('pending', 'retained')",
                           name: 'external_media_repoint_stages_state_check'
      add_index :external_media_repoint_stages, [:available_at, :id],
                name: 'index_ext_media_repoint_stages_on_due',
                where: "state = 'pending'"
    end
  end

  def down
    safety_assured do
      execute "SET lock_timeout = '5s'"
      remove_index :external_media_repoint_stages, name: 'index_ext_media_repoint_stages_on_due'
      remove_check_constraint :external_media_repoint_stages, name: 'external_media_repoint_stages_state_check'
      remove_column :external_media_repoint_stages, :claimed_until
      remove_column :external_media_repoint_stages, :claim_token
      remove_column :external_media_repoint_stages, :failure_code
      remove_column :external_media_repoint_stages, :attempt_count
      remove_column :external_media_repoint_stages, :available_at
      remove_column :external_media_repoint_stages, :state
    end
  end
end
