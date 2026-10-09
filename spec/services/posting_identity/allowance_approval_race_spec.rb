# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'posting identity allowance approval race' do
  self.use_transactional_tests = false

  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user) }

  after do
    PostingIdentityDelegation.delete_all
    PostingIdentityLinkRequest.delete_all
    PostingIdentityRequestAllowance.delete_all
  end

  it 'does not approve a grant after acceptance was revoked' do
    Rails.cache.clear
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
    issued = PostingIdentity::LinkRequestIssuer.call!(
      requester: grantee,
      acct: grantor.account.username,
      scopes: %w(post),
      ip: '203.0.113.30'
    )
    allowance = PostingIdentityRequestAllowance.last
    start = Queue.new
    outcomes = Queue.new

    threads = [
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          PostingIdentity::Approval.call!(approver: User.find(grantor.id), token: issued.token)
          outcomes << :approved
        rescue PostingIdentity::Error => e
          outcomes << e.code
        end
      end,
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          PostingIdentity::RequestAllowance.revoke!(grantor: User.find(grantor.id), allowance: PostingIdentityRequestAllowance.find(allowance.id))
          outcomes << :revoked
        rescue PostingIdentity::Error => e
          outcomes << e.code
        end
      end,
    ]

    2.times { start << true }
    threads.each { |thread| thread.join(10) }

    grant = PostingIdentityDelegation.find_by(grantee_user_id: grantee.id, grantor_user_id: grantor.id)
    allowance.reload
    if grant
      expect(allowance.generation).to eq issued.request.allowance_generation
      expect(grant.approved_at).to be <= (allowance.revoked_at || Time.current)
    else
      expect(issued.request.reload.consumed_at).to be_nil
    end
    expect(PostingIdentityDelegation.where(grantee_user_id: grantee.id).count).to be <= 1
    expect(outcomes.size).to eq 2
  end
end
