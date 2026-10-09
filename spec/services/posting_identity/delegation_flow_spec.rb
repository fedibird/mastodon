# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingIdentity::Approval do # rubocop:disable Metrics/BlockLength
  include ActiveSupport::Testing::TimeHelpers

  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user) }

  def issue!(scopes: %w(post), acct: grantor.account.username, requester: grantee, ip: '203.0.113.10')
    PostingIdentity::LinkRequestIssuer.call!(requester: requester, acct: acct, scopes: scopes, ip: ip)
  end

  before { Rails.cache.clear }

  describe 'requests' do
    it 'lets an administrator tester create a one-time code without storing it' do
      result = issue!(scopes: %w(post media))
      stored = result.request.reload

      expect(stored.requester_user).to eq grantee
      expect(stored.target_user).to eq grantor
      expect(stored.scopes).to eq %w(post media)
      expect(stored.token_digest).to eq PostingIdentityLinkRequest.digest(result.token)
      expect(stored.token_digest).not_to eq result.token
      expect(stored.attributes.values.map(&:to_s).join).not_to include(result.token)
      expect(stored.expires_at).to be_within(1.minute).of(30.minutes.from_now)
    end

    it 'rejects another server, the requester, and unknown scopes' do
      expect { issue!(acct: 'remote@example.com') }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :invalid_target }
      expect { issue!(acct: grantee.account.username) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :self_target }
      expect { issue!(scopes: ['reply']) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :invalid_scopes }
      expect { issue!(requester: grantor) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :not_administrator }
    end

    it 'rate limits a user and an ip separately' do
      10.times { |index| issue!(ip: "203.0.113.#{index}") }

      expect { issue!(ip: '198.51.100.8') }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :rate_limited }

      Rails.cache.clear
      10.times do
        requester = user_with_role('Owner')
        issue!(requester: requester, acct: grantor.account.username, ip: '198.51.100.9')
      end

      expect { issue!(ip: '198.51.100.9') }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :rate_limited }
    end
  end

  describe 'approval' do
    it 'approves only for the target user and only once' do
      result = issue!
      stranger = Fabricate(:user)

      expect { described_class.call!(approver: grantee, token: result.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :not_target }
      expect { described_class.call!(approver: stranger, token: result.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :not_target }
      expect { described_class.call!(approver: grantor, token: 'forged-code') }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :invalid_token }

      delegation = described_class.call!(approver: grantor, token: result.token)

      expect(delegation.grantor_user).to eq grantor
      expect(delegation.grantee_user).to eq grantee
      expect(delegation.posting_account).to eq grantor.account
      expect(delegation.scopes).to eq ['post']
      expect(result.request.reload.consumed_at).to be_present
      expect { described_class.call!(approver: grantor, token: result.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :consumed }
    end

    it 'rejects an expired or canceled request and rolls back a failed approval' do
      expired = issue!
      travel 31.minutes do
        expect { described_class.call!(approver: grantor, token: expired.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :expired }
      end

      canceled = issue!(ip: '203.0.113.40')
      canceled.request.update!(canceled_at: Time.current)
      expect { described_class.call!(approver: grantor, token: canceled.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :canceled }

      failing = issue!(ip: '203.0.113.41')
      allow(PostingIdentityDelegation).to receive(:create!).and_raise(RuntimeError, 'boom')
      expect { described_class.call!(approver: grantor, token: failing.token) }.to raise_error(RuntimeError, 'boom')
      expect(failing.request.reload.consumed_at).to be_nil
      expect(PostingIdentityDelegation.where(grantee_user: grantee)).to be_empty
    end

    it 'does not create a second grant for the same pair' do
      first = issue!
      described_class.call!(approver: grantor, token: first.token)
      second = issue!(ip: '203.0.113.50')

      expect { described_class.call!(approver: grantor, token: second.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :already_delegated }
      expect(second.request.reload.consumed_at).to be_nil
      expect(PostingIdentityDelegation.where(grantee_user: grantee, grantor_user: grantor).count).to eq 1
    end
  end

  describe 'revocation and validity' do
    let(:delegation) { described_class.call!(approver: grantor, token: issue!(scopes: ['post']).token) }

    it 'lets the grantor revoke and does not turn the grant back on' do
      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation)

      expect(delegation.reload.revoked_at).to be_present
      expect { delegation.update!(revoked_at: nil) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: delegation.reload, operation: 'post')).to be false
      expect { PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation.reload) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :not_found }
    end

    it 'lets the grantee remove the link and rejects a stranger' do
      stranger = Fabricate(:user)
      expect { PostingIdentity::Revocation.call!(actor: stranger, delegation: delegation) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :not_owner }

      PostingIdentity::Revocation.call!(actor: grantee, delegation: delegation)

      expect(delegation.reload.revoked_at).to be_present
      expect(PostingIdentity::DelegationResolver.relationship_active?(grantee: grantee, delegation: delegation)).to be false
    end

    it 'rejects an expired grant and a grant whose parties cannot post' do
      record = delegation

      travel 31.days do
        expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: record.reload, operation: 'post')).to be false
      end

      post_only = delegation
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: post_only, operation: 'post')).to be true
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: post_only, operation: 'media')).to be false
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: post_only, operation: 'reply')).to be false

      grantor.account.update!(suspended_at: Time.now.utc)
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: post_only.reload, operation: 'post')).to be false
      grantor.account.update!(suspended_at: nil)

      grantor.settings.disable_post = true
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: post_only.reload, operation: 'post')).to be false
      grantor.settings.disable_post = false

      grantor.disable!
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: post_only.reload, operation: 'post')).to be false
      grantor.enable!

      grantee.disable!
      expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: post_only.reload, operation: 'post')).to be false
    end
  end

  describe 'concurrent approval', :aggregate_failures do
    self.use_transactional_tests = false

    after do
      PostingIdentityDelegation.delete_all
      PostingIdentityLinkRequest.delete_all
    end

    it 'creates one grant when the same code is approved twice' do
      result = issue!
      start = Queue.new
      outcomes = Queue.new

      threads = Array.new(2) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            start.pop
            described_class.call!(approver: User.find(grantor.id), token: result.token)
            outcomes << :ok
          rescue PostingIdentity::Error => e
            outcomes << e.code
          end
        end
      end

      2.times { start << true }
      threads.each { |thread| thread.join(10) }

      codes = Array.new(outcomes.size) { outcomes.pop }

      expect(PostingIdentityDelegation.where(grantee_user_id: grantee.id, grantor_user_id: grantor.id).count).to eq 1
      expect(result.request.reload.consumed_at).to be_present
      expect(codes.count(:ok)).to eq 1
    end
  end
end
