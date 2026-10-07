# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PostingContext::DiscoveryService do # rubocop:disable Metrics/BlockLength
  describe '#call' do # rubocop:disable Metrics/BlockLength
    it 'resolves a local group with built-in Fedibird semantics' do
      account = Fabricate(:account, username: 'group', actor_type: 'Group')

      result = described_class.new.call(account)

      expect(result).to eq(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'resolved',
        context: {
          key: "builtin:fedibird-group:#{account.id}",
          source: {
            id: 'builtin:fedibird-group',
            revision: 1,
          },
          managed: {
            hashtags: [],
            mentions: [
              {
                account_id: account.id.to_s,
                acct: 'group',
                enforcement: 'required',
                rule_id: 'group-account-mention',
              },
            ],
          },
          requirements: {
            following_accounts: [
              {
                account_id: account.id.to_s,
                acct: 'group',
                enforcement: 'required',
                rule_id: 'group-follow',
              },
            ],
          },
          constraints: {
            allowed_visibilities: %w(public unlisted),
          },
        },
        discovery: {
          mechanism: 'built_in',
          adapter: 'fedibird_group',
          authority: 'server',
        },
        viewer_evidence: nil,
      )
      expect(result).not_to have_key(:reason)
      expect(result[:context][:requirements][:following_accounts].first).not_to have_key(:following)
      expect(PostingContext::Adapters::FedibirdGroup.name).to eq('PostingContext::Adapters::FedibirdGroup')
      expect(result.dig(:discovery, :adapter)).to eq('fedibird_group')
    end

    it 'returns unsupported for a remote group without contacting the network' do
      account = Fabricate(:account, username: 'group', domain: 'example.com', actor_type: 'Group')

      expect(Node).not_to receive(:resolve_domain)
      expect(UpdateNodeService).not_to receive(:new)
      expect(ResolveAccountService).not_to receive(:new)

      result = described_class.new.call(account)

      expect(result).to eq(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil,
        discovery: {
          mechanism: nil,
          adapter: nil,
          authority: nil,
        },
        viewer_evidence: nil,
      )
    end

    it 'returns not_applicable for a local person' do
      account = Fabricate(:account, username: 'alice', actor_type: 'Person')

      expect(described_class.new.call(account)).to include(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'not_applicable',
        reason: 'not_group',
        context: nil
      )
    end

    it 'returns not_applicable for a remote person' do
      account = Fabricate(:account, username: 'alice', domain: 'example.com', actor_type: 'Person')

      expect(described_class.new.call(account)).to include(
        status: 'not_applicable',
        reason: 'not_group',
        context: nil
      )
    end

    it 'resolves a remote ActivityPub group from cached Mitra NodeInfo without fetching' do
      account = remote_activitypub_group(domain: 'mitra.example', software_name: 'mitra')

      expect(Node).not_to receive(:resolve_domain)
      expect(UpdateNodeService).not_to receive(:new)
      expect(ResolveAccountService).not_to receive(:new)

      result = described_class.new.call(account)

      expect(result).to eq(
        schema_version: 1,
        account_id: account.id.to_s,
        status: 'resolved',
        context: {
          key: "protocol:fep-1b12-group:#{account.id}",
          source: {
            id: 'compat:mitra-fep-1b12',
            revision: 1,
          },
          managed: {
            hashtags: [],
            mentions: [],
          },
          requirements: {
            following_accounts: [],
          },
          constraints: {
            allowed_visibilities: %w(public unlisted),
          },
          protocol: {
            activitypub: {
              audience: {
                account_id: account.id.to_s,
                acct: 'group@mitra.example',
                enforcement: 'required',
                rule_id: 'fep-1b12-group-audience',
              },
            },
          },
        },
        discovery: {
          mechanism: 'nodeinfo_software',
          adapter: 'mitra_group',
          authority: 'compatibility',
        },
        viewer_evidence: nil,
      )
    end

    it 'matches Mitra software identity case-insensitively and ignores node liveness' do
      account = remote_activitypub_group(domain: 'mixed.example', software_name: 'Mitra', node_status: :gone)

      result = described_class.new.call(account)

      expect(result[:status]).to eq 'resolved'
      expect(result.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(result.dig(:discovery, :authority)).to eq 'compatibility'
    end

    it 'keeps a local Fedibird group ahead of the Mitra compatibility adapter' do
      local_group = Fabricate(:account, username: 'localgroup', actor_type: 'Group')
      remote_group = remote_activitypub_group(domain: 'mitra.example', software_name: 'mitra', username: 'remotegroup')

      fedibird = described_class.new.call(local_group)
      mitra = described_class.new.call(remote_group)

      expect(described_class::ADAPTERS).to eq [
        PostingContext::Adapters::FedibirdGroup,
        PostingContext::Adapters::MitraGroup,
      ]
      expect(fedibird.dig(:discovery, :adapter)).to eq 'fedibird_group'
      expect(fedibird.dig(:discovery, :authority)).to eq 'server'
      expect(fedibird.dig(:context, :managed, :mentions).map { |mention| mention[:rule_id] }).to eq ['group-account-mention']
      expect(fedibird.dig(:context, :requirements, :following_accounts).map { |requirement| requirement[:rule_id] }).to eq ['group-follow']
      expect(fedibird.dig(:context, :constraints, :allowed_visibilities)).to eq %w(public unlisted)
      expect(fedibird[:context]).not_to have_key(:protocol)

      expect(mitra.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(mitra.dig(:discovery, :authority)).to eq 'compatibility'
      expect(mitra.dig(:context, :managed, :mentions)).to eq []
      expect(mitra.dig(:context, :requirements, :following_accounts)).to eq []
      expect(mitra.dig(:context, :constraints, :allowed_visibilities)).to eq %w(public unlisted)
      expect(mitra.dig(:context, :protocol, :activitypub, :audience)).to include(
        account_id: remote_group.id.to_s,
        acct: 'remotegroup@mitra.example',
        enforcement: 'required',
        rule_id: 'fep-1b12-group-audience'
      )
    end

    it 'returns unsupported when a remote group has no cached node' do
      account = remote_activitypub_group(domain: 'missing.example', software_name: :absent)

      expect(Node).not_to receive(:resolve_domain)
      expect(UpdateNodeService).not_to receive(:new)

      expect(described_class.new.call(account)).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
    end

    it 'returns unsupported when cached software identity is blank' do
      blank = remote_activitypub_group(domain: 'blank.example', software_name: '')
      missing = remote_activitypub_group(domain: 'nilinfo.example', software_name: nil)

      [blank, missing].each do |account|
        expect(described_class.new.call(account)).to include(
          status: 'unsupported',
          reason: 'no_supported_adapter',
          context: nil
        )
      end
    end

    it 'does not treat other software, forks, or an upstream name as Mitra' do
      %w(mastodon lemmy friendica nodebb mitra-fork).each do |software_name|
        account = remote_activitypub_group(domain: "#{software_name}.example", software_name: software_name)

        expect(described_class.new.call(account)[:status]).to eq 'unsupported'
      end

      upstream_only = remote_activitypub_group(
        domain: 'upstream.example',
        software_name: 'mastodon',
        upstream_name: 'mitra'
      )

      expect(described_class.new.call(upstream_only)).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
    end

    it 'returns unsupported for a Mitra group that is not an ActivityPub actor with an inbox' do
      ostatus = remote_activitypub_group(domain: 'ostatus.example', software_name: 'mitra', protocol: :ostatus)
      blank_target = remote_activitypub_group(domain: 'blank-target.example', software_name: 'mitra', uri: '', inbox_url: '')

      expect(described_class.new.call(ostatus)).to include(status: 'unsupported', context: nil)
      expect(described_class.new.call(blank_target)).to include(status: 'unsupported', context: nil)
    end

    it 'does not read affiliation cache as posting support or fetch it' do
      account = remote_activitypub_group(domain: 'unknown.example', software_name: :absent)
      account.update_columns(affiliations_url: 'https://unknown.example/groups/group/affiliations', affiliations_fetched_at: Time.utc(2026, 1, 1))
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: 'https://unknown.example/users/alice',
        relationship: 'admin'
      )

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)
      expect(Node).not_to receive(:resolve_domain)
      expect(UpdateNodeService).not_to receive(:new)

      expect(described_class.new.call(account)).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
      expect(a_request(:get, account.affiliations_url)).not_to have_been_made
    end

    it 'keeps Mitra posting context resolution when affiliation metadata is present' do
      account = remote_activitypub_group(domain: 'mitra.example', software_name: 'mitra')
      account.update_columns(affiliations_url: 'https://mitra.example/users/group/affiliations')

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)

      result = described_class.new.call(account)

      expect(result).to include(status: 'resolved')
      expect(result.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(result.dig(:context, :managed, :mentions)).to eq []
      expect(result.dig(:context, :requirements, :following_accounts)).to eq []
      expect(result.dig(:context, :constraints, :allowed_visibilities)).to eq %w(public unlisted)
      expect(result.dig(:context, :protocol, :activitypub, :audience, :rule_id)).to eq 'fep-1b12-group-audience'
      expect(a_request(:get, account.affiliations_url)).not_to have_been_made
    end

    it 'keeps local Fedibird semantics free of remote affiliation evidence' do
      account = Fabricate(:account, username: 'group', actor_type: 'Group')
      viewer = Fabricate(:account, username: 'alice')

      result = described_class.new.call(account, viewer: viewer)

      expect(result[:status]).to eq 'resolved'
      expect(result.dig(:discovery, :adapter)).to eq 'fedibird_group'
      expect(result.dig(:context, :managed, :mentions).map { |mention| mention[:rule_id] }).to eq ['group-account-mention']
      expect(result.dig(:context, :requirements, :following_accounts).map { |requirement| requirement[:rule_id] }).to eq ['group-follow']
      expect(result[:context]).not_to have_key(:protocol)
      expect(result[:viewer_evidence]).to be_nil
    end

    it 'returns fresh viewer affiliation evidence without changing a Mitra context' do
      account = remote_activitypub_group(domain: 'mitra.example', software_name: 'mitra')
      viewer = Fabricate(:account, username: 'alice')
      viewer_uri = ActivityPub::TagManager.instance.uri_for(viewer)
      account.update_columns(affiliations_url: 'https://mitra.example/users/group/affiliations', affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(group_account: account, subject_uri: viewer_uri, relationship: 'admin', affiliation_uri: 'https://mitra.example/relationships/1')
      GroupAffiliation.create!(group_account: account, subject_uri: 'https://other.example/users/bob', relationship: 'admin')

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)
      expect(Node).not_to receive(:resolve_domain)

      result = described_class.new.call(account, viewer: viewer)

      expect(result[:status]).to eq 'resolved'
      expect(result.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(result.dig(:discovery, :authority)).to eq 'compatibility'
      expect(result.dig(:context, :managed, :mentions)).to eq []
      expect(result.dig(:context, :requirements, :following_accounts)).to eq []
      expect(result.dig(:context, :protocol, :activitypub, :audience, :rule_id)).to eq 'fep-1b12-group-audience'
      expect(result.dig(:viewer_evidence, :affiliations, :snapshot_status)).to eq 'fresh'
      expect(result.dig(:viewer_evidence, :affiliations, :relationships)).to eq [
        { relationship: 'admin', affiliation_uri: 'https://mitra.example/relationships/1' },
      ]
      expect(result.dig(:viewer_evidence, :permissions, :create)).to eq(
        status: 'allowed',
        source: 'fep-5219',
        via_relationship: 'admin',
        authority: 'protocol'
      )
    end

    it 'keeps a resolved Mitra context when the fresh affiliation snapshot is empty' do
      account = remote_activitypub_group(domain: 'empty.example', software_name: 'mitra')
      viewer = Fabricate(:account, username: 'alice')
      account.update_columns(affiliations_fetched_at: Time.now.utc)

      result = described_class.new.call(account, viewer: viewer)

      expect(result[:status]).to eq 'resolved'
      expect(result.dig(:context, :protocol, :activitypub, :audience, :rule_id)).to eq 'fep-1b12-group-audience'
      expect(result.dig(:viewer_evidence, :affiliations)).to include(
        snapshot_status: 'fresh',
        relationships: []
      )
      expect(result.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        via_relationship: nil,
        authority: 'protocol'
      )
    end

    it 'keeps a resolved Mitra context when affiliation evidence is stale' do
      account = remote_activitypub_group(domain: 'stale.example', software_name: 'mitra')
      viewer = Fabricate(:account, username: 'alice')
      account.update_columns(affiliations_fetched_at: 2.days.ago)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(viewer),
        relationship: 'admin'
      )

      result = described_class.new.call(account, viewer: viewer)

      expect(result[:status]).to eq 'resolved'
      expect(result.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(result.dig(:viewer_evidence, :affiliations)).to include(
        snapshot_status: 'stale',
        relationships: []
      )
      expect(result.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        via_relationship: nil
      )
    end

    it 'returns affiliation evidence for an unsupported remote group' do
      account = remote_activitypub_group(domain: 'unknown-evidence.example', software_name: :absent)
      viewer = Fabricate(:account, username: 'alice')
      account.update_columns(affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(viewer),
        relationship: 'custom-role',
        affiliation_uri: nil
      )

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)

      result = described_class.new.call(account, viewer: viewer)

      expect(result).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
      expect(result.dig(:viewer_evidence, :affiliations, :snapshot_status)).to eq 'fresh'
      expect(result.dig(:viewer_evidence, :affiliations, :relationships)).to eq [
        { relationship: 'custom-role', affiliation_uri: nil },
      ]
      expect(result.dig(:viewer_evidence, :permissions, :create, :status)).to eq 'unknown'
    end

    it 'keeps a resolved Mitra context when the fresh relationship is custom' do
      account = remote_activitypub_group(domain: 'custom.example', software_name: 'mitra')
      viewer = Fabricate(:account, username: 'alice')
      account.update_columns(affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(viewer),
        relationship: 'trusted-poster'
      )

      result = described_class.new.call(account, viewer: viewer)

      expect(result[:status]).to eq 'resolved'
      expect(result.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(result.dig(:discovery, :authority)).to eq 'compatibility'
      expect(result.dig(:context, :protocol, :activitypub, :audience, :rule_id)).to eq 'fep-1b12-group-audience'
      expect(result.dig(:viewer_evidence, :permissions, :create)).to include(
        status: 'unknown',
        via_relationship: nil,
        source: 'fep-5219',
        authority: 'protocol'
      )
    end

    it 'returns positive create evidence for an unsupported group without inventing a context' do
      account = remote_activitypub_group(domain: 'unknown-admin.example', software_name: :absent)
      viewer = Fabricate(:account, username: 'alice')
      account.update_columns(affiliations_fetched_at: Time.now.utc)
      GroupAffiliation.create!(
        group_account: account,
        subject_uri: ActivityPub::TagManager.instance.uri_for(viewer),
        relationship: 'admin',
        affiliation_uri: 'https://unknown-admin.example/relationships/1'
      )

      expect(ActivityPub::FetchGroupAffiliationsService).not_to receive(:new)
      expect(ActivityPub::SynchronizeGroupAffiliationsWorker).not_to receive(:perform_async)
      expect(Node).not_to receive(:resolve_domain)
      expect(UpdateNodeService).not_to receive(:new)

      result = described_class.new.call(account, viewer: viewer)

      expect(result).to include(
        status: 'unsupported',
        reason: 'no_supported_adapter',
        context: nil
      )
      expect(result.dig(:discovery, :adapter)).to be_nil
      expect(result.dig(:viewer_evidence, :affiliations, :snapshot_status)).to eq 'fresh'
      expect(result.dig(:viewer_evidence, :permissions, :create)).to eq(
        status: 'allowed',
        source: 'fep-5219',
        via_relationship: 'admin',
        authority: 'protocol'
      )
    end

    it 'returns not_applicable for a person on a Mitra server before adapter selection' do
      domain = 'people.example'
      Node.create!(domain: domain, info: { 'software_name' => 'mitra' })
      account = Fabricate(
        :account,
        username: 'alice',
        domain: domain,
        actor_type: 'Person',
        protocol: :activitypub,
        uri: "https://#{domain}/users/alice",
        inbox_url: "https://#{domain}/users/alice/inbox"
      )

      expect(PostingContext::Adapters::MitraGroup.applicable?(account)).to be false
      expect(described_class.new.call(account)).to include(
        status: 'not_applicable',
        reason: 'not_group',
        context: nil
      )
    end
  end

  def remote_activitypub_group(domain:, software_name:, **account_attrs)
    username = account_attrs.delete(:username) || 'group'
    node_status = account_attrs.delete(:node_status) || :up
    upstream_name = account_attrs.delete(:upstream_name)

    unless software_name == :absent
      info = {}
      info['software_name'] = software_name unless software_name.nil?
      info['upstream_name'] = upstream_name if upstream_name
      Node.create!(domain: domain, info: info, status: node_status)
    end

    Fabricate(
      :account,
      {
        username: username,
        domain: domain,
        actor_type: 'Group',
        protocol: :activitypub,
        uri: "https://#{domain}/users/#{username}",
        inbox_url: "https://#{domain}/users/#{username}/inbox",
      }.merge(account_attrs)
    )
  end
end
