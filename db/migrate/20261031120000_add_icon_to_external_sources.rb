# frozen_string_literal: true

# Shared feed icon for an external RSS/Atom source (issue #569).
#
# Every column is nullable or has a constant default, so on PostgreSQL 11+
# this is a catalog-only change and no existing external_sources row is
# rewritten. No index is added: the table holds one row per distinct public
# feed and the backfill scheduler reads a bounded batch.
#
# icon_* Paperclip columns hold the stored image (served through Fedibird's
# own storage, never the original URL). The remaining columns are the
# minimum bookkeeping the fetch job needs: where the image came from, the
# validators for a conditional re-check, the feed-declared candidates,
# and the retry state.
class AddIconToExternalSources < ActiveRecord::Migration[6.1]
  # strong_migrations cannot inspect change_table bulk: true, so each column is
  # its own catalog-only statement.
  # rubocop:disable Rails/BulkChangeTable
  def change
    add_column :external_sources, :icon_file_name, :string
    add_column :external_sources, :icon_content_type, :string
    add_column :external_sources, :icon_file_size, :bigint
    add_column :external_sources, :icon_updated_at, :datetime
    add_column :external_sources, :icon_fingerprint, :string
    add_column :external_sources, :icon_remote_url, :text
    add_column :external_sources, :icon_origin, :string
    add_column :external_sources, :icon_etag, :text
    add_column :external_sources, :icon_last_modified, :text
    add_column :external_sources, :icon_hints, :jsonb
    add_column :external_sources, :icon_checked_at, :datetime
    add_column :external_sources, :icon_next_check_at, :datetime
    add_column :external_sources, :icon_failure_count, :integer, null: false, default: 0
    add_column :external_sources, :icon_error_code, :string
  end
  # rubocop:enable Rails/BulkChangeTable
end
