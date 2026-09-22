class AddActionReviewExecutedAtToAccountMigrations < ActiveRecord::Migration[6.1]
  def change
    add_column :account_migrations, :action_review_executed_at, :datetime
  end
end
