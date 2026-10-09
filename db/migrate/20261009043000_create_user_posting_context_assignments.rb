# frozen_string_literal: true

class CreateUserPostingContextAssignments < ActiveRecord::Migration[6.1]
  def change
    create_table :user_posting_context_assignments do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :surface_kind, null: false, limit: 16
      t.string :surface_key, null: false, limit: 100
      t.references :user_posting_context, foreign_key: { on_delete: :nullify }, index: { name: 'index_upca_on_user_posting_context_id' }
      t.integer :lock_version, null: false, default: 0

      t.timestamps

      t.index [:user_id, :surface_kind, :surface_key],
              unique: true,
              name: 'index_upca_on_user_id_and_surface'
    end
  end
end
