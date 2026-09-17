# frozen_string_literal: true

require Rails.root.join('lib', 'mastodon', 'migration_helpers')

class AddCategoryAndRuleIdsToReports < ActiveRecord::Migration[6.1]
  include Mastodon::MigrationHelpers

  disable_ddl_transaction!

  def up
    safety_assured do
      add_column_with_default :reports, :category, :integer, default: 0, allow_null: false
      add_column :reports, :rule_ids, :bigint, array: true
    end
  end

  def down
    change_table :reports, bulk: true do |t|
      t.remove :rule_ids
      t.remove :category
    end
  end
end
