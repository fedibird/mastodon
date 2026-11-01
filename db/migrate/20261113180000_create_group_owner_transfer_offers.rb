# frozen_string_literal: true

# A durable offer, not a change of ownership. Existing groups are not
# enrolled and no roles or follows are modified by this migration.
class CreateGroupOwnerTransferOffers < ActiveRecord::Migration[6.1]
  def change
    create_table :group_owner_transfer_offers do |t|
      t.references :group_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }
      t.references :offered_by_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }
      t.references :candidate_account, null: false, foreign_key: { to_table: :accounts, on_delete: :restrict }
      t.integer :state, null: false, default: 0
      t.datetime :expires_at, null: false
      t.datetime :responded_at
      t.timestamps
    end

    add_index :group_owner_transfer_offers, :group_account_id, unique: true,
              where: 'state = 0', name: 'index_group_owner_transfer_offers_one_pending'
    add_index :group_owner_transfer_offers, [:candidate_account_id, :state, :expires_at],
              name: 'index_group_owner_transfer_offers_incoming'
    add_check_constraint :group_owner_transfer_offers, 'state IN (0, 1, 2)',
                         name: 'group_owner_transfer_offers_state_known'
    response_shape = <<~SQL.squish
      (state = 0 AND responded_at IS NULL)
      OR (state IN (1, 2) AND responded_at IS NOT NULL)
    SQL
    add_check_constraint :group_owner_transfer_offers, response_shape,
                         name: 'group_owner_transfer_offers_response_shape'
    add_check_constraint :group_owner_transfer_offers, 'offered_by_account_id <> candidate_account_id',
                         name: 'group_owner_transfer_offers_distinct_people'
    add_check_constraint :group_owner_transfer_offers, 'candidate_account_id <> group_account_id',
                         name: 'group_owner_transfer_offers_candidate_not_group'
  end
end
