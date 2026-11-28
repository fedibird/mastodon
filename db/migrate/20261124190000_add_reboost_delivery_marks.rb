# frozen_string_literal: true

class AddReboostDeliveryMarks < ActiveRecord::Migration[6.1]
  def change
    add_column :reboost_operations, :undo_enqueued_at, :datetime
    add_column :reboost_operations, :local_enqueued_at, :datetime
    add_column :reboost_operations, :federation_enqueued_at, :datetime

    create_table :reboost_count_releases, primary_key: :status_id do |t|
      t.timestamps
    end
  end
end
