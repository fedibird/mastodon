# frozen_string_literal: true

# Article-level author hints and the byline last shown to a subscriber.
#
# author_hints defaults to {} so existing external_resources rows stay empty
# without a rewrite or a backfill. last_seen_byline is nullable. A projection
# that has never recorded a byline stores the current value on the next
# refresh and does not emit a content notification for that first record.
# No production backfill is part of this migration.
class AddExternalAuthorHints < ActiveRecord::Migration[6.1]
  def change
    add_column :external_resources, :author_hints, :jsonb, null: false, default: {}
    add_column :external_status_projections, :last_seen_byline, :text
  end
end
