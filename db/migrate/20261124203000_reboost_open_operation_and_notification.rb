# frozen_string_literal: true

class ReboostOpenOperationAndNotification < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def change
    add_column :reboost_operations, :notification_enqueued_at, :datetime

    add_index :reboost_operations, [:account_id, :reblog_of_id],
              unique: true,
              where: "state IN ('pending', 'federating')",
              name: 'index_reboost_operations_one_open',
              algorithm: :concurrently
    add_index :reboost_operations, [:local_enqueued_at, :notification_enqueued_at, :federation_enqueued_at],
              where: "state = 'federating'",
              name: 'index_reboost_operations_federating_delivery',
              algorithm: :concurrently
  end
end
