# frozen_string_literal: true

class AddAudienceAccountToStatuses < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def change
    add_reference :statuses, :audience_account, index: { algorithm: :concurrently }
  end
end
