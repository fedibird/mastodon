# frozen_string_literal: true

class AddLanguagesToFollowsAndFollowRequests < ActiveRecord::Migration[6.1]
  def change
    add_column :follows, :languages, :string, array: true
    add_column :follow_requests, :languages, :string, array: true
  end
end
