# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::StatusesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'poster')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'author')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'write:statuses read:statuses') }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
  end

  def delegate!(scopes: %w(post group))
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: scopes, ip: '203.0.113.70')
    PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
  end

  def community(software, domain = "#{software}.example", username = 'technology')
    Node.create!(domain: domain, info: { 'software_name' => software })
    Fabricate(
      :account,
      username: username,
      domain: domain,
      actor_type: 'Group',
      protocol: :activitypub,
      uri: "https://#{domain}/c/#{username}",
      inbox_url: "https://#{domain}/c/#{username}/inbox"
    )
  end

  def permit_create!(target, affiliation: 'none', actor: grantor.account)
    target.update_columns(
      affiliations_fetched_at: Time.now.utc,
      permission_definitions_fetched_at: Time.now.utc,
      can_create_affiliation: affiliation
    )
    return if affiliation == 'none'

    GroupAffiliation.create!(
      group_account: target,
      subject_uri: ActivityPub::TagManager.instance.uri_for(actor),
      relationship: affiliation,
      affiliation_uri: "https://#{target.domain}/relationships/#{affiliation}"
    )
  end

  def group_params(target, software, extra = {})
    {
      status: "@technology@#{target.domain} Hello community",
      visibility: 'public',
      posting_identity_id: "delegated:#{grantor.account.id}",
      posting_context_account_id: target.id,
      posting_context_key: "protocol:fep-1b12-#{software}:#{target.id}",
      posting_context_revision: 1,
      audience_account_id: target.id,
    }.merge(extra)
  end

  describe 'POST #create Lemmy and PieFed groups' do
    it 'recognizes the context and still refuses a delegated post, including one with fresh canCreate' do
      delegate!(scopes: %w(post))
      lemmy = community('lemmy')
      permit_create!(lemmy)

      expect { post :create, params: group_params(lemmy, 'lemmy') }.not_to change(Status, :count)
      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: PostingIdentityDelegation.last.id).update_all(scopes: %w(post group))

      %w(lemmy piefed).each do |software|
        target = software == 'lemmy' ? lemmy : community('piefed')
        permit_create!(target)

        expect { post :create, params: group_params(target, software) }.not_to change(Status, :count)
        expect(response).to have_http_status(422)
        expect(ActivityPub::DistributionWorker).not_to have_received(:perform_async)
      end
    end

    it 'does not accept A affiliation, unknown evidence, a changed audience, or a private post' do
      delegate!
      target = community('lemmy', 'evidence.example')
      permit_create!(target, affiliation: 'trusted-poster', actor: grantee.account)

      expect { post :create, params: group_params(target, 'lemmy') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)

      target.update_columns(permission_definitions_fetched_at: nil, can_create_affiliation: nil)

      expect { post :create, params: group_params(target, 'lemmy', status: '@technology@evidence.example Unknown') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)

      permit_create!(target)
      other = community('piefed', 'other.example', 'other')
      permit_create!(other)

      expect { post :create, params: group_params(target, 'lemmy', audience_account_id: other.id) }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(target, 'lemmy', posting_context_key: "protocol:fep-1b12-nodebb:#{target.id}") }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(target, 'lemmy', posting_context_revision: 2) }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(target, 'lemmy', visibility: 'private') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(target, 'lemmy', status: 'Hello without the community') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(target, 'lemmy', status: '@technology@evidence.example Hello @stranger') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect(PostingIdentityPost.count).to eq 0
    end

    it 'does not create a titled post or a duplicate when the request is repeated' do
      delegate!
      target = community('piefed', 'repeat.example')
      permit_create!(target)
      request.headers['Idempotency-Key'] = 'threadiverse-refused'

      2.times do
        expect { post :create, params: group_params(target, 'piefed', status: "@technology@#{target.domain} Title line\n\nBody") }.not_to change(Status, :count)
        expect(response).to have_http_status(422)
      end

      expect(Status.where(account: grantor.account)).to be_empty
      expect(PostingIdentityPost.count).to eq 0
    end
  end
end
