# frozen_string_literal: true

class CreateCustomFilterTags < ActiveRecord::Migration[6.1]
  def change
    create_table :custom_filter_tags do |t|
      t.references :custom_filter, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.text :name, null: false
      t.timestamps
    end

    add_index :custom_filter_tags, [:account_id, :name], unique: true, name: 'index_custom_filter_tags_on_account_id_and_name'
  end
end
