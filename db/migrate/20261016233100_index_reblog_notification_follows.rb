# frozen_string_literal: true

class IndexReblogNotificationFollows < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def change
    add_index :follows, [:target_account_id, :id], where: 'notify_reblogs',
              name: 'index_follows_on_reblog_notifications', algorithm: :concurrently
  end
end
