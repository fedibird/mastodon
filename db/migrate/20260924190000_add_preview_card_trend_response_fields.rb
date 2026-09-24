# frozen_string_literal: true

class AddPreviewCardTrendResponseFields < ActiveRecord::Migration[6.1]
  def change
    add_column :preview_cards, :image_description, :string, default: '', null: false
    add_column :preview_cards, :published_at, :datetime
  end
end
