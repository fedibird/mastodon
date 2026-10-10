# frozen_string_literal: true

# The account that will own a status, plus the grant used to choose it.
# delegated? is false for the signed-in account, including when the client
# names that account as local:<id>.
class PostingIdentity::Resolution
  attr_reader :account, :identity_id, :delegation

  def initialize(account:, identity_id:, delegation: nil)
    @account = account
    @identity_id = identity_id
    @delegation = delegation
  end

  def delegated?
    !@delegation.nil?
  end
end
