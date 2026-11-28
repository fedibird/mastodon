# frozen_string_literal: true

class AddRemoteReboostHoldDelivery < ActiveRecord::Migration[6.1]
  def change
    change_table :remote_reboost_holds, bulk: true do |t|
      t.column :apply_enqueued_at, :datetime
      t.column :delivery_options, :jsonb, default: {}, null: false
    end
  end
end
