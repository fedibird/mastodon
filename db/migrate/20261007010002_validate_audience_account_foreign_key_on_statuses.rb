# frozen_string_literal: true

class ValidateAudienceAccountForeignKeyOnStatuses < ActiveRecord::Migration[6.1]
  def up
    validate_foreign_key :statuses, :accounts, column: :audience_account_id
  end

  def down
    # Validation does not change the constraint's delete behavior.
    # Rolling back the previous migration removes the foreign key.
  end
end
