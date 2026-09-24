# frozen_string_literal: true

class AddPublicTrendsFoundations < ActiveRecord::Migration[6.1]
  def change
    create_table :preview_card_providers do |t|
      t.string :domain, null: false, default: ''
      t.attachment :icon
      t.boolean :trendable
      t.datetime :reviewed_at
      t.datetime :requested_review_at
      t.timestamps
    end
    add_index :preview_card_providers, :domain, unique: true

    create_table :preview_card_trends do |t|
      t.references :preview_card, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.float :score, null: false, default: 0
      t.integer :rank, null: false, default: 0
      t.boolean :allowed, null: false, default: false
      t.string :language
    end

    create_table :status_trends do |t|
      t.references :status, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.float :score, null: false, default: 0
      t.integer :rank, null: false, default: 0
      t.boolean :allowed, null: false, default: false
      t.string :language
    end

    add_column :preview_cards, :language, :string
    add_column :preview_cards, :max_score, :float
    add_column :preview_cards, :max_score_at, :datetime
    add_column :preview_cards, :trendable, :boolean
    add_column :preview_cards, :link_type, :integer

    add_column :accounts, :trendable, :boolean
    add_column :accounts, :reviewed_at, :datetime
    add_column :accounts, :requested_review_at, :datetime

    add_column :statuses, :trendable, :boolean
  end
end
