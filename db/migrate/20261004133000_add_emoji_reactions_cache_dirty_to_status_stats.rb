# frozen_string_literal: true

require Rails.root.join('lib', 'mastodon', 'migration_helpers')

class AddEmojiReactionsCacheDirtyToStatusStats < ActiveRecord::Migration[6.1]
  include Mastodon::MigrationHelpers

  disable_ddl_transaction!

  INDEX_NAME = 'index_status_stats_on_dirty_emoji_reactions_cache'

  # Existing rows stay clean. PostgreSQL 11+ adds this boolean default without
  # a table rewrite. Every SET runs inside safety_assured: Strong Migrations
  # rejects raw execute, and an ensure outside that block hides the first error.
  # A failed CREATE INDEX CONCURRENTLY can leave an INVALID index. Rails 6.1
  # index_exists? ignores pg_index.indisvalid, so that leftover must be dropped
  # before the index is created again.
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

        if index_exists?(:status_stats, :status_id, name: INDEX_NAME) && !index_valid?(INDEX_NAME)
          remove_concurrent_index_by_name :status_stats, INDEX_NAME
        end

        unless index_exists?(:status_stats, :status_id, name: INDEX_NAME)
          add_concurrent_index :status_stats,
                               :status_id,
                               name: INDEX_NAME,
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

        if index_exists?(:status_stats, :status_id, name: INDEX_NAME)
          remove_concurrent_index_by_name :status_stats, INDEX_NAME
        end

        remove_column :status_stats, :emoji_reactions_cache_dirty if column_exists?(:status_stats, :emoji_reactions_cache_dirty)
      ensure
        execute 'SET lock_timeout TO DEFAULT'
        execute 'SET statement_timeout TO DEFAULT'
      end
    end
  end

  private

  # select_value returns TrueClass or FalseClass: the pg decoder casts bool
  # before Active Record sees it. == true rejects "t", 1, and nil. A missing
  # index is false via COALESCE.
  def index_valid?(name)
    select_value(<<~SQL.squish) == true
      SELECT COALESCE(
        (
          SELECT indisvalid
          FROM pg_index
          WHERE indexrelid = to_regclass(#{connection.quote(name)})
        ),
        FALSE
      )
    SQL
  end
end
