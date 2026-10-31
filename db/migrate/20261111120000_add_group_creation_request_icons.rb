# frozen_string_literal: true

# Private icon metadata for a group creation request. This does not add a
# Paperclip attachment. The bytes live outside public storage. See
# docs/group_management_p1.md. 4194304 is AccountAvatar::LIMIT (4 MiB).
#
# The table was created empty by 20261110120000. A short lock inside one
# transaction is enough. A failure rolls the columns, indexes, and checks
# back together, so a re-run does not hit a leftover column.
class AddGroupCreationRequestIcons < ActiveRecord::Migration[6.1]
  ICON_INDEX = 'index_group_creation_requests_on_icon_storage_key'
  TOKEN_INDEX = 'index_group_creation_requests_on_submission_token'
  ICON_CHECK = 'group_creation_requests_icon_shape'
  TOKEN_CHECK = 'group_creation_requests_submission_token_shape'

  ICON_SQL = <<~SQL.squish
    (
      icon_storage_key IS NULL
      AND icon_content_type IS NULL
      AND icon_byte_size IS NULL
      AND icon_purged_at IS NULL
    ) OR (
      icon_storage_key ~ '^[0-9a-f]{64}$'
      AND icon_content_type IN (
        'image/jpeg',
        'image/png',
        'image/gif',
        'image/webp',
        'image/bmp',
        'image/vnd.microsoft.icon'
      )
      AND icon_byte_size IS NOT NULL
      AND icon_byte_size > 0
      AND icon_byte_size < 4194304
    )
  SQL
  TOKEN_SQL = "submission_token IS NULL OR submission_token ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'"

  def up
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      add_icon_columns
      add_index :group_creation_requests, :icon_storage_key, unique: true, where: 'icon_storage_key IS NOT NULL', name: ICON_INDEX
      add_index :group_creation_requests, :submission_token, unique: true, where: 'submission_token IS NOT NULL', name: TOKEN_INDEX
      add_check_constraint :group_creation_requests, ICON_SQL, name: ICON_CHECK
      add_check_constraint :group_creation_requests, TOKEN_SQL, name: TOKEN_CHECK
    end
  end

  def down
    safety_assured do
      execute "SET LOCAL lock_timeout TO '5s'"
      remove_check_constraint :group_creation_requests, name: ICON_CHECK
      remove_check_constraint :group_creation_requests, name: TOKEN_CHECK
      remove_index :group_creation_requests, name: ICON_INDEX
      remove_index :group_creation_requests, name: TOKEN_INDEX
      remove_icon_columns
    end
  end

  private

  def add_icon_columns
    add_column :group_creation_requests, :icon_storage_key, :string
    add_column :group_creation_requests, :icon_content_type, :string
    add_column :group_creation_requests, :icon_byte_size, :integer
    add_column :group_creation_requests, :icon_purged_at, :datetime
    add_column :group_creation_requests, :submission_token, :string
  end

  def remove_icon_columns
    remove_column :group_creation_requests, :submission_token
    remove_column :group_creation_requests, :icon_purged_at
    remove_column :group_creation_requests, :icon_byte_size
    remove_column :group_creation_requests, :icon_content_type
    remove_column :group_creation_requests, :icon_storage_key
  end
end
