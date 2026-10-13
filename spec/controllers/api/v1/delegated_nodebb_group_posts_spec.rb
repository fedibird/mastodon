# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::StatusesController, type: :controller do # rubocop:disable Metrics/BlockLength
  render_views

  let(:grantee) { user_with_role('Owner', account: Fabricate(:account, username: 'poster')) }
  let(:grantor) { Fabricate(:user, account: Fabricate(:account, username: 'author')) }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: grantee.id, scopes: 'write:statuses read:statuses') }
  let(:group) { nodebb_group }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
    allow(LocalNotificationWorker).to receive(:perform_async)
    allow(LinkCrawlWorker).to receive(:perform_async)
    allow(DistributionWorker).to receive(:perform_async)
    allow(ActivityPub::DistributionWorker).to receive(:perform_async)
  end

  def delegate!(scopes: %w(post group))
    PostingIdentity::RequestAllowance.permit!(grantor: grantor, acct: grantee.account.username, scopes: scopes)
    issued = PostingIdentity::LinkRequestIssuer.call!(requester: grantee, acct: grantor.account.username, scopes: scopes, ip: '203.0.113.60')
    PostingIdentity::Approval.call!(approver: grantor, token: issued.token)
  end

  def nodebb_group(domain = 'nodebb.example', username = 'category')
    Node.create!(domain: domain, info: { 'software_name' => 'nodebb' })
    Fabricate(
      :account,
      username: username,
      domain: domain,
      actor_type: 'Group',
      protocol: :activitypub,
      uri: "https://#{domain}/category/#{username}",
      inbox_url: "https://#{domain}/category/#{username}/inbox"
    )
  end

  def permit_create!(target = group, affiliation: 'none', actor: grantor.account)
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

  def group_params(extra = {})
    {
      status: '@category@nodebb.example Hello category',
      visibility: 'public',
      posting_identity_id: "delegated:#{grantor.account.id}",
      posting_context_account_id: group.id,
      posting_context_key: "protocol:fep-1b12-nodebb:#{group.id}",
      posting_context_revision: 1,
      audience_account_id: group.id,
    }.merge(extra)
  end

  def activity_json(status)
    JSON.parse(ActiveModelSerializers::SerializableResource.new(
      ActivityPub::ActivityPresenter.from_status(status),
      serializer: ActivityPub::ActivitySerializer,
      adapter: ActivityPub::Adapter
    ).to_json)
  end

  describe 'POST #create remote NodeBB groups' do # rubocop:disable Metrics/BlockLength
    it 'refuses post without group and unknown, unfetched, or stale canCreate' do
      delegation = delegate!(scopes: %w(post))
      permit_create!

      expect { post :create, params: group_params }.not_to change(Status, :count)
      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: %w(post group))
      group.update_columns(permission_definitions_fetched_at: nil, can_create_affiliation: nil, affiliations_fetched_at: nil)

      expect { post :create, params: group_params }.not_to change(Status, :count)
      expect(response).to have_http_status(422)

      group.update_columns(affiliations_fetched_at: Time.now.utc, permission_definitions_fetched_at: 2.days.ago, can_create_affiliation: 'none')

      expect { post :create, params: group_params(status: '@category@nodebb.example Stale definition') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
    end

    it 'publishes a public category post as B when canCreate is none' do
      delegation = delegate!
      permit_create!

      post :create, params: group_params

      status = grantor.account.statuses.last
      json = activity_json(status)
      worker = ActivityPub::DistributionWorker.new
      worker.instance_variable_set(:@status, status)
      worker.instance_variable_set(:@account, status.account)
      tags = Array(json.dig('object', 'tag'))

      expect(response).to have_http_status(200)
      expect(status.account_id).to eq grantor.account.id
      expect(status.audience_account_id).to eq group.id
      expect(status.visibility).to eq 'public'
      expect(status.mentions.map(&:account_id)).to eq [group.id]
      expect(grantee.account.statuses).to be_empty
      expect(json['actor']).to eq ActivityPub::TagManager.instance.uri_for(grantor.account)
      expect(json.dig('object', 'attributedTo')).to eq ActivityPub::TagManager.instance.uri_for(grantor.account)
      expect(json.dig('object', 'audience')).to eq group.uri
      expect(json.dig('object', 'context')).not_to eq group.uri
      expect(json['to']).to include('https://www.w3.org/ns/activitystreams#Public', group.uri)
      expect(json['to']).not_to include("#{group.uri}/followers")
      expect(tags).to include(include('type' => 'Mention', 'href' => group.uri, 'name' => '@category@nodebb.example'))
      expect(worker.send(:with_audience_inbox, [])).to include(group.inbox_url)
      expect(ActivityPub::DistributionWorker).to have_received(:perform_async).with(status.id)
      expect(PostingIdentityPost.where(status_id: status.id, delegation_id: delegation.id, posting_account_id: grantor.account.id).count).to eq 1
    end

    it 'allows the affiliation named by canCreate only for B' do
      delegate!
      permit_create!(affiliation: 'trusted-poster', actor: grantee.account)

      expect { post :create, params: group_params }.not_to change(Status, :count)
      expect(response).to have_http_status(422)

      GroupAffiliation.create!(
        group_account: group,
        subject_uri: ActivityPub::TagManager.instance.uri_for(grantor.account),
        relationship: 'trusted-poster'
      )

      post :create, params: group_params(status: '@category@nodebb.example From B')

      expect(response).to have_http_status(200)
      expect(grantor.account.statuses.last.audience_account_id).to eq group.id

      group.update_columns(affiliations_fetched_at: 2.days.ago)

      expect { post :create, params: group_params(status: '@category@nodebb.example Stale affiliation') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
    end

    it 'rejects a mismatched audience, key, revision, or non-public visibility' do
      delegate!
      permit_create!
      other = nodebb_group('other.example', 'other')
      permit_create!(other)

      expect { post :create, params: group_params(audience_account_id: other.id) }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(posting_context_key: "protocol:fep-1b12-group:#{group.id}") }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(posting_context_revision: 2) }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(visibility: 'unlisted') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(visibility: 'private') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
    end

    it 'rejects a missing body mention, a content-warning-only mention, and any other mention' do
      delegate!
      permit_create!
      other = nodebb_group('forum.example', 'forum')
      permit_create!(other)

      expect { post :create, params: group_params(status: 'Hello category') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(status: 'Hello category', spoiler_text: 'cw @category@nodebb.example') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(status: '@forum@forum.example Hello') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(status: '@category@nodebb.example Hello @stranger') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(status: '@category@nodebb.example Hello', spoiler_text: 'cw @stranger') }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
    end

    it 'rejects replies, quotes, Lemmy, and PieFed' do
      delegate!(scopes: %w(post group reply quote))
      permit_create!
      parent = Fabricate(:status, account: grantor.account, visibility: :public, text: 'Parent')

      expect { post :create, params: group_params(in_reply_to_id: parent.id) }.not_to change(Status, :count)
      expect(response).to have_http_status(422)
      expect { post :create, params: group_params(quote_id: parent.id) }.not_to change(Status, :count)
      expect(response).to have_http_status(422)

      %w(lemmy piefed).each do |software|
        remote = nodebb_group("#{software}.example", 'forum')
        remote.node.update!(info: { 'software_name' => software })
        permit_create!(remote)

        expect do
          post :create, params: group_params(
            status: "@forum@#{software}.example Hello",
            posting_context_account_id: remote.id,
            posting_context_key: "protocol:fep-1b12-#{software}:#{remote.id}",
            audience_account_id: remote.id
          )
        end.not_to change(Status, :count)
        expect(response).to have_http_status(422)
      end
    end

    it 'keeps media on the granting delegation and does not repeat an idempotent post' do
      delegation = delegate!(scopes: %w(post group))
      permit_create!
      media = Fabricate(:media_attachment, account: grantor.account, status: nil)
      PostingIdentityMedia.create!(grantee_user: grantee, delegation: delegation, posting_account: grantor.account, media_attachment: media)

      expect { post :create, params: group_params(media_ids: [media.id]) }.not_to change(Status, :count)
      expect(response).to have_http_status(403)

      PostingIdentityDelegation.where(id: delegation.id).update_all(scopes: %w(post group media))
      request.headers['Idempotency-Key'] = 'nodebb-group-once'
      post :create, params: group_params(media_ids: [media.id])
      status = grantor.account.statuses.last

      expect(response).to have_http_status(200)
      expect(status.media_attachments.map(&:id)).to eq [media.id]
      expect(status.account_id).to eq grantor.account.id
      expect(status.audience_account_id).to eq group.id

      expect { post :create, params: group_params(media_ids: [media.id]) }.not_to change(grantor.account.statuses, :count)
      expect(PostingIdentityPost.where(delegation_id: delegation.id).count).to eq 1

      PostingIdentity::Revocation.call!(actor: grantor, delegation: delegation.reload)
      request.headers['Idempotency-Key'] = 'nodebb-group-revoked'

      expect { post :create, params: group_params(status: '@category@nodebb.example After revoke') }.not_to change(Status, :count)
      expect(response).to have_http_status(403)
    end
  end
end
