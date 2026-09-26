# frozen_string_literal: true

class CreateWebhooks < ActiveRecord::Migration[6.1]
  def change
    create_table :webhooks do |t|
      t.string :url, null: false
      t.string :events, array: true, null: false, default: []
      t.string :secret, null: false, default: ''
      t.boolean :enabled, null: false, default: true
      t.text :template

      t.timestamps
    end

    add_index :webhooks, :url, unique: true
  end
end
