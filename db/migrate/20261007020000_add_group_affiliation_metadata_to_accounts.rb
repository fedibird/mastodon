# frozen_string_literal: true

class AddGroupAffiliationMetadataToAccounts < ActiveRecord::Migration[6.1]
  def change
    add_column :accounts, :affiliations_url, :string
    add_column :accounts, :affiliations_fetched_at, :datetime
  end
end
