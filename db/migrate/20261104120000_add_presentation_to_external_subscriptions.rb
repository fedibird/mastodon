# frozen_string_literal: true

# Per-subscription RSS display choices (issue #596).
#
# media_sensitive and cw_enabled belong to the subscriber, not to the shared
# feed cache. presentation_revision is the generation the owner asked for.
# presentation_applied_revision is the generation whose statuses are fully
# rewritten. A worker that still holds an older generation must not finish
# it, so a later save always wins. presentation_lease_until stops the
# recovery scheduler from queueing a second pass while one is in flight.
#
# Every column has a constant default, so on PostgreSQL 11+ this is a
# catalog-only change. Existing rows stay "settled, both off", which matches
# the statuses already stored. Nothing here rewrites `statuses`.
class AddPresentationToExternalSubscriptions < ActiveRecord::Migration[6.1]
  # strong_migrations cannot inspect change_table bulk: true, so each column is
  # its own catalog-only statement.
  # rubocop:disable Rails/BulkChangeTable
  def change
    add_column :external_subscriptions, :media_sensitive, :boolean, null: false, default: false
    add_column :external_subscriptions, :cw_enabled, :boolean, null: false, default: false
    add_column :external_subscriptions, :presentation_revision, :bigint, null: false, default: 0
    add_column :external_subscriptions, :presentation_applied_revision, :bigint, null: false, default: 0
    add_column :external_subscriptions, :presentation_error, :string
    add_column :external_subscriptions, :presentation_lease_until, :datetime
  end
  # rubocop:enable Rails/BulkChangeTable
end
