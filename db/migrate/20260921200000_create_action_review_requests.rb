# frozen_string_literal: true

class CreateActionReviewRequests < ActiveRecord::Migration[6.1]
  def change
    create_table :action_review_requests do |t|
      t.string :operation_type, null: false
      t.integer :state, null: false, default: 0

      t.references :actor_account, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.string :resource_type, null: false
      t.bigint :resource_id, null: false

      t.string :trigger, null: false
      t.string :signal_level, null: false
      t.string :policy_mode, null: false
      t.string :policy_version, null: false
      t.string :evaluator_version

      t.jsonb :reason_codes, null: false, default: []
      t.jsonb :evidence, null: false, default: {}

      t.datetime :requested_at, null: false
      t.datetime :reviewed_at
      t.references :reviewer_account, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.text :decision_note

      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end

    add_index :action_review_requests,
              [:operation_type, :resource_type, :resource_id],
              unique: true,
              where: 'state = 0',
              name: :index_action_review_requests_on_pending_resource
  end
end
