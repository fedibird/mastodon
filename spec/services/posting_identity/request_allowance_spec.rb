# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingIdentity::RequestAllowance do # rubocop:disable Metrics/BlockLength
  include ActiveSupport::Testing::TimeHelpers

  let(:grantee) { user_with_role('Owner') }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'allowing')) }
  let(:other) { user_with_role('Owner') }

  def permit!(scopes: %w(post media), acct: grantee.account.username, owner: grantor)
    described_class.permit!(grantor: owner, acct: acct, scopes: scopes)
  end

  def request!(scopes: %w(post), acct: grantor.account.username, requester: grantee, ip: '203.0.113.15')
    PostingIdentity::LinkRequestIssuer.call!(requester: requester, acct: acct, scopes: scopes, ip: ip)
  end

  before { Rails.cache.clear }

  it 'refuses a request until B allows A, and does not reveal whether B exists' do
    missing = nil
    unallowed = nil

    expect { request!(acct: 'nobody-here') }.to raise_error(PostingIdentity::Error) { |error| missing = error }
    expect { request! }.to raise_error(PostingIdentity::Error) { |error| unallowed = error }

    expect(missing.code).to eq :request_unavailable
    expect(unallowed.code).to eq missing.code
    expect(unallowed.message).to eq missing.message
    expect(PostingIdentityLinkRequest.count).to eq 0
  end

  it 'lets only the allowed account request, and only within the allowed scopes' do
    permit!(scopes: %w(post))

    expect { request!(requester: other, ip: '203.0.113.16') }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :request_unavailable }
    expect { request!(scopes: %w(post media)) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :request_unavailable }
    expect(PostingIdentityLinkRequest.count).to eq 0

    issued = request!
    expect(issued.token).to be_present
    expect(issued.request.allowance_generation).to eq 1
    expect(issued.request.request_allowance.requester_user).to eq grantee
  end

  it 'rejects an expired allowance and a second open request for the same pair' do
    permit!
    travel 8.days do
      expect { request! }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :request_unavailable }
    end

    permit!
    request!(ip: '203.0.113.17')
    expect { request!(ip: '203.0.113.18') }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :duplicate_request }
    expect(PostingIdentityLinkRequest.count).to eq 1
  end

  it 'invalidates outstanding codes when acceptance is revoked and later granted again' do
    permit!
    issued = request!
    described_class.revoke!(grantor: grantor, allowance: PostingIdentityRequestAllowance.last)

    expect { request!(ip: '203.0.113.19') }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :request_unavailable }
    expect { PostingIdentity::Approval.call!(approver: grantor, token: issued.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :allowance_inactive }

    permit!
    expect(PostingIdentityRequestAllowance.last.generation).to eq 2
    expect { PostingIdentity::Approval.call!(approver: grantor, token: issued.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :allowance_inactive }

    issued.request.update!(canceled_at: Time.current)
    replacement = request!(ip: '203.0.113.21')
    delegation = PostingIdentity::Approval.call!(approver: grantor, token: replacement.token)

    expect(delegation.grantee_user).to eq grantee
    expect(replacement.request.allowance_generation).to eq 2
  end

  it 'does not treat an allowance as a delegation, or an old request without one as approvable' do
    permit!
    issued = request!
    delegation = PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
    described_class.revoke!(grantor: grantor, allowance: PostingIdentityRequestAllowance.last)

    expect(delegation.reload.revoked_at).to be_nil
    expect(PostingIdentity::DelegationResolver.grant_permits?(grantee: grantee, delegation: delegation, operation: 'post')).to be true

    permit!
    legacy = request!(ip: '203.0.113.22')
    PostingIdentityLinkRequest.where(id: legacy.request.id).update_all(request_allowance_id: nil, allowance_generation: nil)
    expect { PostingIdentity::Approval.call!(approver: grantor, token: legacy.token) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :allowance_inactive }
  end

  it 'does not let anyone but B change the allowance' do
    record = permit!
    expect { described_class.permit!(grantor: grantee, acct: grantor.account.username, scopes: %w(post)) }.not_to raise_error
    expect { described_class.revoke!(grantor: grantee, allowance: record) }.to raise_error(PostingIdentity::Error) { |error| expect(error.code).to eq :not_owner }
    expect(record.reload.revoked_at).to be_nil
  end
end
