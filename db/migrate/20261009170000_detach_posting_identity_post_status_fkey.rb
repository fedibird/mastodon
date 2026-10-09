# frozen_string_literal: true

class DetachPostingIdentityPostStatusFkey < ActiveRecord::Migration[6.1]
  def up
    if foreign_key_exists?(:posting_identity_posts, :statuses)
      remove_foreign_key :posting_identity_posts, :statuses
    end

    replace_foreign_key(:users, :grantee_user_id)
    replace_foreign_key(:accounts, :posting_account_id)
    replace_foreign_key(:posting_identity_delegations, :delegation_id)
  end

  def down
    add_foreign_key :posting_identity_posts, :statuses unless foreign_key_exists?(:posting_identity_posts, :statuses)
  end

  private

  # The table is created in the previous migration. Replacing the delete
  # action does not rewrite rows. Existing rows are validated separately.
  def replace_foreign_key(to_table, column)
    remove_foreign_key :posting_identity_posts, column: column if foreign_key_exists?(:posting_identity_posts, column: column)
    add_foreign_key :posting_identity_posts, to_table, column: column, on_delete: :cascade, validate: false
  end
end
