# frozen_string_literal: true

class AddEmojiReactionRepresentativeScanIndexes < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  # Performance-only INCLUDE indexes. db/schema.rb creates the same indexes
  # with non-concurrent SQL because Rails 6.1 cannot dump INCLUDE. Do not
  # replace that SQL with the 3-column t.index lines db:schema:dump emits.
  # Production applies the CONCURRENTLY statements below.
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
