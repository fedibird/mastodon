# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::Fedibird::Accounts::PostingContextsController do # rubocop:disable Metrics/BlockLength
  render_views

  let(:user) { Fabricate(:user) }
  let(:scopes) { 'read:accounts' }
  let(:token) { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: scopes) }

  before do
    allow(controller).to receive(:doorkeeper_token) { token }
  end

  describe 'GET #show' do # rubocop:disable Metrics/BlockLength
    it 'returns a resolved local group context' do
      account = Fabricate(:account, username: 'group', actor_type: 'Group')

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'resolved'
      )
      expect(body_as_json[:context][:managed][:mentions].first[:acct]).to eq 'group'
      expect(body_as_json[:discovery]).to eq(
        mechanism: 'built_in',
        adapter: 'fedibird_group',
        authority: 'server'
      )
      expect(body_as_json[:viewer_evidence]).to be_nil
    end

    it 'returns unsupported for a remote group' do
      account = Fabricate(:account, username: 'group', domain: 'example.com', actor_type: 'Group')

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
    end

    it 'returns a resolved Mitra group audience context from cached software identity' do
      Node.create!(domain: 'mitra.example', info: { 'software_name' => 'mitra' })
      account = Fabricate(
        :account,
        username: 'group',
        domain: 'mitra.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://mitra.example/users/group',
        inbox_url: 'https://mitra.example/users/group/inbox'
      )

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'resolved'
      )
      expect(body_as_json[:discovery]).to eq(
        mechanism: 'nodeinfo_software',
        adapter: 'mitra_group',
        authority: 'compatibility'
      )
      expect(body_as_json.dig(:context, :managed, :mentions)).to eq []
      expect(body_as_json.dig(:context, :requirements, :following_accounts)).to eq []
      expect(body_as_json.dig(:context, :constraints, :allowed_visibilities)).to eq %w(public unlisted)
      expect(body_as_json.dig(:context, :protocol, :activitypub, :audience)).to eq(
        account_id: account.id.to_s,
        acct: 'group@mitra.example',
        enforcement: 'required',
        rule_id: 'fep-1b12-group-audience'
      )
    end

    it 'returns unsupported for a remote group whose cached software is unknown' do
      Node.create!(domain: 'unknown.example', info: { 'software_name' => '' })
      account = Fabricate(
        :account,
        username: 'group',
        domain: 'unknown.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://unknown.example/users/group',
        inbox_url: 'https://unknown.example/users/group/inbox'
      )

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
    end

    it 'returns fresh viewer-specific affiliation evidence with an unchanged Mitra context' do
      Node.create!(domain: 'mitra.example', info: { 'software_name' => 'mitra' })
      account = Fabricate(
        :account,
        username: 'group',
        domain: 'mitra.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://mitra.example/users/group',
        inbox_url: 'https://mitra.example/users/group/inbox'
      )
      viewer_uri = ActivityPub::TagManager.instance.uri_for(user.account)
      account.update_columns(affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(group_account: account, subject_uri: viewer_uri, relationship: 'admin', affiliation_uri: 'https://mitra.example/relationships/1')
      GroupAffiliation.create!(group_account: account, subject_uri: 'https://other.example/users/bob', relationship: 'trusted-poster')

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(status: 'resolved', schema_version: 1)
      expect(body_as_json.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(body_as_json.dig(:discovery, :authority)).to eq 'compatibility'
      expect(body_as_json.dig(:context, :managed, :mentions)).to eq []
      expect(body_as_json.dig(:context, :protocol, :activitypub, :audience, :rule_id)).to eq 'fep-1b12-group-audience'
      expect(body_as_json.dig(:viewer_evidence, :affiliations, :snapshot_status)).to eq 'fresh'
      expect(body_as_json.dig(:viewer_evidence, :affiliations, :relationships)).to eq [
        { relationship: 'admin', affiliation_uri: 'https://mitra.example/relationships/1' },
      ]
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        via_relationship: nil,
        authority: 'protocol'
      )
    end

    it 'returns allowed create evidence when canCreate names the viewer affiliation' do
      account = mitra_group('publisher.example')
      account.update_columns(
        affiliations_fetched_at: Time.now.utc,
        can_create_affiliation: 'trusted-poster',
        permission_definitions_fetched_at: Time.now.utc
      )
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(user.account),
        relationship: 'trusted-poster',
        affiliation_uri: 'https://publisher.example/relationships/1'
      )

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq 'resolved'
      expect(body_as_json[:schema_version]).to eq 1
      expect(body_as_json.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(body_as_json.dig(:discovery, :authority)).to eq 'compatibility'
      expect(body_as_json.dig(:context, :protocol, :activitypub, :audience, :rule_id)).to eq 'fep-1b12-group-audience'
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to eq(
        status: 'allowed',
        source: 'fep-5219',
        via_relationship: 'trusted-poster',
        authority: 'protocol'
      )
      expect(body_as_json[:viewer_evidence]).not_to have_key(:permission_definitions)
    end

    it 'returns allowed create evidence for admin only when canCreate names admin' do
      account = mitra_group('named-admin.example')
      account.update_columns(
        affiliations_fetched_at: Time.now.utc,
        can_create_affiliation: 'admin',
        permission_definitions_fetched_at: Time.now.utc
      )
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(user.account),
        relationship: 'admin'
      )

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq 'resolved'
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'allowed',
        via_relationship: 'admin',
        authority: 'protocol'
      )
    end

    it 'keeps a resolved Mitra context when the fresh affiliation snapshot is empty' do
      account = mitra_group('empty.example')
      account.update_columns(affiliations_fetched_at: Time.now.utc)

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq 'resolved'
      expect(body_as_json.dig(:context, :protocol, :activitypub, :audience, :rule_id)).to eq 'fep-1b12-group-audience'
      expect(body_as_json.dig(:viewer_evidence, :affiliations, :snapshot_status)).to eq 'fresh'
      expect(body_as_json.dig(:viewer_evidence, :affiliations, :relationships)).to eq []
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        via_relationship: nil,
        authority: 'protocol'
      )
    end

    it 'keeps a resolved Mitra context for a fresh custom relationship' do
      account = mitra_group('custom.example')
      account.update_columns(affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(user.account),
        relationship: 'trusted-poster'
      )

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq 'resolved'
      expect(body_as_json.dig(:discovery, :authority)).to eq 'compatibility'
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        source: 'fep-5219',
        via_relationship: nil,
        authority: 'protocol'
      )
    end

    it 'keeps a resolved Mitra context when affiliation evidence is stale' do
      account = mitra_group('stale.example')
      account.update_columns(affiliations_fetched_at: 2.days.ago)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(user.account),
        relationship: 'admin'
      )

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json[:status]).to eq 'resolved'
      expect(body_as_json.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(body_as_json.dig(:viewer_evidence, :affiliations)).to include(
        snapshot_status: 'stale',
        relationships: []
      )
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        via_relationship: nil
      )
    end

    it 'returns affiliation evidence for an unsupported remote group' do
      account = Fabricate(
        :account,
        username: 'group',
        domain: 'unknown.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://unknown.example/users/group',
        inbox_url: 'https://unknown.example/users/group/inbox'
      )
      account.update_columns(affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(user.account),
        relationship: 'custom-role',
        affiliation_uri: nil
      )

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
      expect(body_as_json.dig(:viewer_evidence, :affiliations, :snapshot_status)).to eq 'fresh'
      expect(body_as_json.dig(:viewer_evidence, :affiliations, :relationships)).to eq [
        { relationship: 'custom-role', affiliation_uri: nil },
      ]
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create, :status)).to eq 'unknown'
    end

    it 'leaves create unknown for an unsupported remote group when admin has no canCreate definition' do
      account = Fabricate(
        :account,
        username: 'group',
        domain: 'unknown-admin.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://unknown-admin.example/users/group',
        inbox_url: 'https://unknown-admin.example/users/group/inbox'
      )
      account.update_columns(affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(user.account),
        relationship: 'admin',
        affiliation_uri: 'https://unknown-admin.example/relationships/1'
      )

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
      expect(body_as_json.dig(:viewer_evidence, :affiliations, :snapshot_status)).to eq 'fresh'
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        via_relationship: nil
      )
    end

    it 'returns allowed create evidence for an unsupported remote group when canCreate matches' do
      account = Fabricate(
        :account,
        username: 'group',
        domain: 'unknown-create.example',
        actor_type: 'Group',
        protocol: :activitypub,
        uri: 'https://unknown-create.example/users/group',
        inbox_url: 'https://unknown-create.example/users/group/inbox'
      )
      account.update_columns(
        affiliations_fetched_at: Time.now.utc,
        can_create_affiliation: 'trusted-poster',
        permission_definitions_fetched_at: Time.now.utc
      )
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(user.account),
        relationship: 'trusted-poster'
      )

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
      expect(body_as_json.dig(:viewer_evidence, :permissions, :create)).to eq(
        status: 'allowed',
        source: 'fep-5219',
        via_relationship: 'trusted-poster',
        authority: 'protocol'
      )
    end

    it 'returns not_applicable for a person' do
      account = Fabricate(:account, username: 'alice')

      get :show, params: { account_id: account.id }

      expect(response).to have_http_status(200)
      expect(body_as_json).to include(
        status: 'not_applicable',
        reason: 'not_group',
        context: nil
      )
    end

    it 'returns not found for an unknown account' do
      get :show, params: { account_id: 99_999_999_999 }

      expect(response).to have_http_status(404)
    end

    def mitra_group(domain)
      Node.create!(domain: domain, info: { 'software_name' => 'mitra' })
      Fabricate(
        :account,
        username: 'group',
        domain: domain,
        actor_type: 'Group',
        protocol: :activitypub,
        uri: "https://#{domain}/users/group",
        inbox_url: "https://#{domain}/users/group/inbox"
      )
    end

    context 'with the wrong scope' do
      let(:scopes) { 'write:statuses' }

      it 'returns http forbidden' do
        account = Fabricate(:account, username: 'group', actor_type: 'Group')

        get :show, params: { account_id: account.id }

        expect(response).to have_http_status(403)
      end
    end

    context 'without an oauth token' do
      before do
        allow(controller).to receive(:doorkeeper_token) { nil }
      end

      it 'returns http unauthorized' do
        account = Fabricate(:account, username: 'group', actor_type: 'Group')

        get :show, params: { account_id: account.id }

        expect(response).to have_http_status(401)
      end
    end
  end
end
