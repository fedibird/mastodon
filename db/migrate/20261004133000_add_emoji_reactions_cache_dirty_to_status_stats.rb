# frozen_string_literal: true

require Rails.root.join('lib', 'mastodon', 'migration_helpers')

class AddEmojiReactionsCacheDirtyToStatusStats < ActiveRecord::Migration[6.1]
  include Mastodon::MigrationHelpers

  disable_ddl_transaction!

  # Existing rows stay clean. PostgreSQL 11+ adds this boolean default without
  # a table rewrite. Every SET runs inside safety_assured: Strong Migrations
  # rejects raw execute, and an ensure outside that block hides the first error.
  def up
    safety_assured do
      begin
        execute "SET lock_timeout TO '5s'"

        unless column_exists?(:status_stats, :emoji_reactions_cache_dirty)
          add_column :status_stats,
                     :emoji_reactions_cache_dirty,
                     :boolean,
                     null: false,
                     default: false
        end

        unless index_exists?(:status_stats, :status_id, name: 'index_status_stats_on_dirty_emoji_reactions_cache')
          add_concurrent_index :status_stats,
                               :status_id,
                               name: 'index_status_stats_on_dirty_emoji_reactions_cache',
                               where: 'emoji_reactions_cache_dirty = TRUE'
        end
      ensure
        execute 'SET lock_timeout TO DEFAULT'
        execute 'SET statement_timeout TO DEFAULT'
      end
    end
  end

  def down
    safety_assured do
      begin
        execute "SET lock_timeout TO '5s'"

        if index_exists?(:status_stats, :status_id, name: 'index_status_stats_on_dirty_emoji_reactions_cache')
          remove_concurrent_index_by_name :status_stats, 'index_status_stats_on_dirty_emoji_reactions_cache'
        end

        remove_column :status_stats, :emoji_reactions_cache_dirty if column_exists?(:status_stats, :emoji_reactions_cache_dirty)
      ensure
        execute 'SET lock_timeout TO DEFAULT'
        execute 'SET statement_timeout TO DEFAULT'
      end
    end
  end
end
