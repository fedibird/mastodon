# frozen_string_literal: true

# Keywords copied from an external RSS item (issue #597).
#
# The jsonb default is a constant, so PostgreSQL 11+ does not rewrite
# existing external_resources rows. Nothing backfills old items.
class AddExternalResourceKeywords < ActiveRecord::Migration[6.1]
  def change
    add_column :external_resources, :keywords, :jsonb, null: false, default: []
  end
end
