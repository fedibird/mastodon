# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'posting identity allowance races' do # rubocop:disable Metrics/BlockLength
  self.use_transactional_tests = false

  def with_connection(&block)
    ActiveRecord::Base.connection_pool.with_connection(&block)
  end

  def cleanup_users(user_ids)
    ids = Array(user_ids).compact
    return if ids.empty?

    PostingIdentityDelegation.where(grantor_user_id: ids).or(PostingIdentityDelegation.where(grantee_user_id: ids)).delete_all
    PostingIdentityLinkRequest.where(requester_user_id: ids).or(PostingIdentityLinkRequest.where(target_user_id: ids)).delete_all
    PostingIdentityRequestAllowance.where(grantor_user_id: ids).or(PostingIdentityRequestAllowance.where(requester_user_id: ids)).delete_all
    users = User.where(id: ids).to_a
    account_ids = users.map(&:account_id)
    users.each do |user|
      user.session_activations.delete_all
      user.destroy!
    end
    Account.where(id: account_ids).find_each(&:destroy!)
  end

  def finish(threads)
    Array(threads).compact.each { |thread| thread.join(10) }
  end

  it 'refuses approval when revoke commits while holding the allowance lock' do
    grantee = nil
    grantor = nil
    threads = []
    release = Queue.new
    Rails.cache.clear
    grantee = user_with_role('Owner')
    grantor = Fabricate(:user)
    threads = []
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.40')
    allowance_id = PostingIdentityRequestAllowance.last.id
    ready = Queue.new
    release = Queue.new
    outcome = Queue.new

    threads << Thread.new do
      with_connection do
        PostingIdentityRequestAllowance.transaction do
          PostingIdentityRequestAllowance.lock.find(allowance_id)
          ready << true
          release.pop
          PostingIdentityRequestAllowance.find(allowance_id).update!(revoked_at: Time.current)
        end
      end
    end

    ready.pop
    threads << Thread.new do
      with_connection do
        PostingIdentity::Approval.call!(approver: User.find(grantor.id), token: issued.token)
        outcome << :approved
      rescue PostingIdentity::Error => e
        outcome << e.code
      end
    end

    sleep 0.2
    expect(threads.last.status).not_to eq false
    release << true
    finish(threads)

    expect(outcome.pop).to eq :allowance_inactive
    expect(issued.request.reload.consumed_at).to be_nil
    expect(PostingIdentityDelegation.where(grantee_user_id: grantee.id, grantor_user_id: grantor.id)).to be_empty
  ensure
    release << true if release
    finish(threads)
    cleanup_users([grantee&.id, grantor&.id])
  end

  it 'keeps an approved grant when revoke waits for the approval lock' do
    grantee = nil
    grantor = nil
    threads = []
    go = Queue.new
    Rails.cache.clear
    grantee = user_with_role('Owner')
    grantor = Fabricate(:user)
    threads = []
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: %w(post))
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: %w(post), ip: '203.0.113.41')
    allowance_id = PostingIdentityRequestAllowance.last.id
    arrived = Queue.new

    allow(PostingIdentityDelegation).to receive(:create!).and_wrap_original do |original, *args, **kwargs|
      arrived << true
      go.pop
      original.call(*args, **kwargs)
    end

    threads << Thread.new do
      with_connection do
        PostingIdentity::Approval.call!(approver: User.find(grantor.id), token: issued.token)
      end
    end
    arrived.pop

    threads << Thread.new do
      with_connection do
        PostingIdentity::RequestAllowance.revoke!(grantor: User.find(grantor.id), allowance: PostingIdentityRequestAllowance.find(allowance_id))
      end
    end
    sleep 0.2
    expect(threads.last.status).not_to eq false
    go << true
    finish(threads)

    grant = PostingIdentityDelegation.find_by!(grantee_user_id: grantee.id, grantor_user_id: grantor.id)
    expect(grant.revoked_at).to be_nil
    expect(PostingIdentityRequestAllowance.find(allowance_id).revoked_at).to be_present
    expect(issued.request.reload.consumed_at).to be_present
  ensure
    allow(PostingIdentityDelegation).to receive(:create!).and_call_original
    go << true if go
    finish(threads)
    cleanup_users([grantee&.id, grantor&.id])
  end

  it 'stores one allowance when two permits insert at the same time' do
    grantee = nil
    grantor = nil
    threads = []
    Rails.cache.clear
    grantee = user_with_role('Owner')
    grantor = Fabricate(:user)
    threads = []
    start = Queue.new
    saved = Queue.new
    errors = Queue.new

    threads = 2.times.map do
      Thread.new do
        with_connection do
          start.pop
          record = PostingIdentity::RequestAllowance.permit!(
            grantor: User.find(grantor.id),
            acct: grantee.account.username,
            scopes: %w(post)
          )
          saved << record.id
        rescue StandardError => e
          errors << "#{e.class}:#{e.message}"
        end
      end
    end

    2.times { start << true }
    finish(threads)

    rows = PostingIdentityRequestAllowance.where(grantor_user_id: grantor.id, requester_user_id: grantee.id)
    expect(errors.size).to eq 0
    expect(rows.count).to eq 1
    expect(rows.first.generation).to eq 1
    expect(saved.size).to eq 2
  ensure
    finish(threads)
    cleanup_users([grantee&.id, grantor&.id])
  end
end
