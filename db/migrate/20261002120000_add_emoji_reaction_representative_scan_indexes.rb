# frozen_string_literal: true

class AddEmojiReactionRepresentativeScanIndexes < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  # Performance-only INCLUDE indexes. Rails 6.1 cannot dump or load INCLUDE,
  # and recording the included column as a normal key would create a different
  # index. db/schema.rb therefore does not list these indexes. db:schema:dump
  # will try to add the wrong 3-column form; do not commit that output.
  def up
    safety_assured do
      execute <<~SQL.squish
        CREATE INDEX CONCURRENTLY IF NOT EXISTS index_emoji_reactions_on_account_status_include_id
        ON emoji_reactions (account_id, status_id)
        INCLUDE (id)
      SQL

      execute <<~SQL.squish
        CREATE INDEX CONCURRENTLY IF NOT EXISTS index_emoji_reactions_on_account_id_and_id_include_status_id
        ON emoji_reactions (account_id, id)
        INCLUDE (status_id)
      SQL
    end
  end

  def down
    safety_assured do
      execute 'DROP INDEX CONCURRENTLY IF EXISTS index_emoji_reactions_on_account_id_and_id_include_status_id'
      execute 'DROP INDEX CONCURRENTLY IF EXISTS index_emoji_reactions_on_account_status_include_id'
    end
  end
end
