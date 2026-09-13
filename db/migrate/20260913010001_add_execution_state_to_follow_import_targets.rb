# frozen_string_literal: true

class AddExecutionStateToFollowImportTargets < ActiveRecord::Migration[6.1]
  def change
    # state defaults to 0 (pending) so existing rows are safely treated as
    # not-yet-executed. On PostgreSQL 11+ adding a column with a constant default
    # is a metadata-only change (no table rewrite).
    safety_assured do
      add_column :follow_import_targets, :state, :integer, null: false, default: 0
      add_column :follow_import_targets, :follow_request_uri, :string
      add_column :follow_import_targets, :queued_at, :datetime
      add_column :follow_import_targets, :delivered_at, :datetime
      add_column :follow_import_targets, :response_deadline_at, :datetime
      add_column :follow_import_targets, :completed_at, :datetime
      add_column :follow_import_targets, :delivery_attempts, :integer, null: false, default: 0
      add_column :follow_import_targets, :failure_code, :string
    end
  end
end
