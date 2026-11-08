# frozen_string_literal: true

class CreatePersonalEmojiSets < ActiveRecord::Migration[6.1]
  def change
    create_table :personal_emoji_sets do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.jsonb :categories, null: false, default: []
      t.bigint :revision, null: false, default: 0
      t.timestamps
    end
  end
end
