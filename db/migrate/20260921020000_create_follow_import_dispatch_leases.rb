# frozen_string_literal: true

class CreateFollowImportDispatchLeases < ActiveRecord::Migration[6.1]
  def up
    create_table :follow_import_dispatch_leases do |t|
      t.string :owner_token
      t.bigint :fencing_generation, null: false, default: 0
      t.datetime :expires_at
      t.timestamps
    end

    execute <<~SQL.squish
      INSERT INTO follow_import_dispatch_leases (id, fencing_generation, created_at, updated_at)
      VALUES (1, 0, NOW(), NOW())
    SQL
  end

  def down
    drop_table :follow_import_dispatch_leases
  end
end
