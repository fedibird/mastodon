# frozen_string_literal: true

class AddNotifyReblogsToFollows < ActiveRecord::Migration[6.1]
  def change
    # Constant defaults use PostgreSQL 11+ fast defaults (no table rewrite).
    # Bound the brief catalog locks instead of waiting behind long transactions.
    safety_assured { execute "SET LOCAL lock_timeout = '5s'" }
    add_column :follows, :notify_reblogs, :boolean, null: false, default: false
    add_column :follow_requests, :notify_reblogs, :boolean, null: false, default: false
  end
end
