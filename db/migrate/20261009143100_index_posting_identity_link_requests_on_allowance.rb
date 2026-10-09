# frozen_string_literal: true

class IndexPostingIdentityLinkRequestsOnAllowance < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  def change
    add_index :posting_identity_link_requests, :request_allowance_id,
              name: 'index_posting_identity_link_requests_on_allowance_id',
              algorithm: :concurrently
  end
end