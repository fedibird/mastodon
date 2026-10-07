# frozen_string_literal: true

class CreateGroupAffiliations < ActiveRecord::Migration[6.1]
  def change
    create_table :group_affiliations do |t|
      t.references :group_account, null: false, foreign_key: { to_table: :accounts, on_delete: :cascade }
      t.string :subject_uri, null: false
      t.string :relationship, null: false
      t.string :affiliation_uri

      t.timestamps
    end

    add_index :group_affiliations,
              [:group_account_id, :subject_uri, :relationship],
              unique: true,
              name: 'index_group_affiliations_on_identity'
  end
end
