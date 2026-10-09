# frozen_string_literal: true

class ValidatePostingIdentityPostForeignKeys < ActiveRecord::Migration[6.1]
  def change
    validate_foreign_key :posting_identity_posts, :users
    validate_foreign_key :posting_identity_posts, :accounts
    validate_foreign_key :posting_identity_posts, :posting_identity_delegations
  end
end
