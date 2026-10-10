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

  # Irreversible. 20261009160000 does not create a status foreign key.
  # Databases that already ran an older copy of that migration lose the
  # key here. Putting it back would fail once a status has been deleted
  # and the audit row still holds that status_id.
  def down
    raise ActiveRecord::IrreversibleMigration, <<~MSG.squish
      posting_identity_posts.status_id is an identifier, not a foreign key.
      Rolling this migration back would restore a foreign key that a fresh
      install never creates, and that foreign key cannot be validated after
      RemoveStatusService has deleted the status.
    MSG
  end

  private

  # The table is created in the previous migration. Replacing the delete
  # action does not rewrite rows. Existing rows are validated separately.
  def replace_foreign_key(to_table, column)
    remove_foreign_key :posting_identity_posts, column: column if foreign_key_exists?(:posting_identity_posts, column: column)
    add_foreign_key :posting_identity_posts, to_table, column: column, on_delete: :cascade, validate: false
  end
end
