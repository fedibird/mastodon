# frozen_string_literal: true

require Rails.root.join('lib', 'mastodon', 'migration_helpers')

class AddEmojiReactionsCacheDirtyToStatusStats < ActiveRecord::Migration[6.1]
  include Mastodon::MigrationHelpers

  disable_ddl_transaction!

  # Existing rows stay clean. A metadata-only default on PostgreSQL 11+ avoids
  # a table rewrite and a deploy-time rebuild of every emoji reaction cache.
  def up
    disable_statement_timeout

    safety_assured do
      add_column :status_stats, :emoji_reactions_cache_dirty, :boolean, null: false, default: false
    end

    safety_assured do
      execute <<~SQL.squish
        CREATE INDEX CONCURRENTLY IF NOT EXISTS index_status_stats_on_dirty_emoji_reactions_cache
        ON status_stats (status_id)
        WHERE emoji_reactions_cache_dirty = TRUE
      SQL
    end
  ensure
    execute('SET statement_timeout TO DEFAULT')
  end

  def down
    disable_statement_timeout

    safety_assured do
      execute 'DROP INDEX CONCURRENTLY IF EXISTS index_status_stats_on_dirty_emoji_reactions_cache'
    end

    safety_assured do
      remove_column :status_stats, :emoji_reactions_cache_dirty
    end
  ensure
    execute('SET statement_timeout TO DEFAULT')
  end
end
