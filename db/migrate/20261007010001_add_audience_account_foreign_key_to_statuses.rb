# frozen_string_literal: true

class AddAudienceAccountForeignKeyToStatuses < ActiveRecord::Migration[6.1]
  def change
    add_foreign_key :statuses, :accounts, column: :audience_account_id, on_delete: :nullify, validate: false
  end
end
