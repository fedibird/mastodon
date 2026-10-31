# frozen_string_literal: true

# Private icon metadata for a group creation request. This does not add a
# Paperclip attachment. The bytes live outside public storage. See
# docs/group_management_p1.md. 4194304 is AccountAvatar::LIMIT (4 MiB).
class AddGroupCreationRequestIcons < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  ICON_INDEX = 'index_group_creation_requests_on_icon_storage_key'
  TOKEN_INDEX = 'index_group_creation_requests_on_submission_token'
  ICON_CHECK = 'group_creation_requests_icon_shape'
  TOKEN_CHECK = 'group_creation_requests_submission_token_shape'

  # New columns are null on every existing row, so the checks pass.
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
    add_column :group_creation_requests, :icon_storage_key, :string
    add_column :group_creation_requests, :icon_content_type, :string
    add_column :group_creation_requests, :icon_byte_size, :integer
    add_column :group_creation_requests, :icon_purged_at, :datetime
    add_column :group_creation_requests, :submission_token, :string

    add_concurrent_index(ICON_INDEX, :icon_storage_key, 'icon_storage_key IS NOT NULL')
    add_concurrent_index(TOKEN_INDEX, :submission_token, 'submission_token IS NOT NULL')

    add_check_constraint :group_creation_requests, ICON_SQL, name: ICON_CHECK, validate: false
    add_check_constraint :group_creation_requests, TOKEN_SQL, name: TOKEN_CHECK, validate: false
    validate_check_constraint :group_creation_requests, name: ICON_CHECK
    validate_check_constraint :group_creation_requests, name: TOKEN_CHECK
  end

  def down
    remove_check_constraint :group_creation_requests, name: ICON_CHECK
    remove_check_constraint :group_creation_requests, name: TOKEN_CHECK

    safety_assured do
      execute 'SET lock_timeout TO 0'
      remove_index :group_creation_requests, name: ICON_INDEX, algorithm: :concurrently, if_exists: true
      remove_index :group_creation_requests, name: TOKEN_INDEX, algorithm: :concurrently, if_exists: true
    ensure
      execute 'SET lock_timeout TO DEFAULT'
    end

    remove_column :group_creation_requests, :submission_token
    remove_column :group_creation_requests, :icon_purged_at
    remove_column :group_creation_requests, :icon_byte_size
    remove_column :group_creation_requests, :icon_content_type
    remove_column :group_creation_requests, :icon_storage_key
  end

  private

  def add_concurrent_index(name, column, where_sql)
    safety_assured do
      execute 'SET lock_timeout TO 0'
      add_index :group_creation_requests, column, unique: true, where: where_sql, name: name, algorithm: :concurrently, if_not_exists: true
    ensure
      execute 'SET lock_timeout TO DEFAULT'
    end
  end
end
