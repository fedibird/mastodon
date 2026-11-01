# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GroupProtocol do # rubocop:disable Metrics/BlockLength
  def remote_group(domain, username: 'group', uri: nil, **attrs)
    Fabricate(
      :account,
      {
        username: username,
        domain: domain,
        actor_type: 'Group',
        protocol: :activitypub,
        uri: uri || "https://#{domain}/users/#{username}",
        inbox_url: "https://#{domain}/inbox",
      }.merge(attrs)
    )
  end

  def create_node(domain, software:, upstream: 'mastodon', fetched_at: Time.current, nodeinfo: { 'software' => { 'name' => software } }, info_override: nil, **extra)
    Node.create!(
      domain: domain,
      info: {
        'software_name' => software,
        'software_version' => '1.2.3',
        'upstream_name' => upstream,
        'upstream_version' => '4.3.0',
      }.compact.merge(extra),
      info_override: info_override,
      nodeinfo: nodeinfo,
      last_fetched_at: fetched_at
    )
  end

  def capability(assessment, name, scope: :actor)
    key = scope == :viewer ? :viewer_capabilities : :actor_capabilities
    assessment[key].find { |row| row[:name] == name }
  end

  describe '.assess' do # rubocop:disable Metrics/BlockLength
    it 'describes a local group from server authority and does not authorize posting' do
      account = Fabricate(:account, username: 'group', actor_type: 'Group')

      result = described_class.assess(account)

      expect(result).to include(
        schema_version: 1,
        account_id: account.id.to_s,
        group: true,
        local: true,
        remote_fedibird: 'not_applicable',
        fedibird_posting: 'server_local',
        authorizes_posting: false,
        compatibility_candidates: [],
        viewer_capabilities: nil
      )
      expect(result[:implementation]).to include(
        identity: 'server',
        family: 'fedibird',
        software_name: 'fedibird',
        fedibird_named: false,
        evidence: include(source: 'server', authority: 'server', freshness: 'current', uncertainty: 'none')
      )
      expect(result[:profile]).to include(
        kind: 'fedibird_mention_follow_announce',
        delivery: 'announce_original_uri',
        requires_mention: true,
        requires_follow: true,
        allowed_visibilities: %w(public unlisted),
        evidence: include(source: 'builtin:fedibird-group', authority: 'server')
      )
      expect(capability(result, 'requires_group_mention')).to include(state: 'observed', value: true, scope: 'actor')
      expect(capability(result, 'group_announce_delivery')).to include(state: 'observed', value: 'announce_original_uri')
      expect(capability(result, 'allowed_visibilities')).to include(state: 'observed', value: %w(public unlisted))
      expect(capability(result, 'fep_1b12_audience')).to include(state: 'denied', value: false)
      expect(capability(result, 'fep_400e_append')).to include(state: 'denied', value: false)
      expect(capability(result, 'roles_independent_of_follow')).to include(state: 'observed', value: true)
      expect(capability(result, 'remote_posting_released')).to include(state: 'withheld', value: false)
      expect(result[:actor_capabilities].map { |row| row[:name] }).to eq described_class::ACTOR_CAPABILITIES
    end

    it 'keeps a local group on the server profile when the local domain node claims another implementation' do
      Node.create!(
        domain: Rails.configuration.x.local_domain,
        info: { 'software_name' => 'lemmy', 'upstream_name' => 'lemmy' },
        nodeinfo: { 'software' => { 'name' => 'lemmy' } },
        last_fetched_at: Time.current
      )
      account = Fabricate(:account, username: 'group', actor_type: 'Group', display_name: 'Fedibird FEP-1b12')

      result = described_class.assess(account)

      expect(result[:implementation][:identity]).to eq 'server'
      expect(result[:profile][:kind]).to eq 'fedibird_mention_follow_announce'
      expect(result[:compatibility_candidates]).to eq []
    end

    it 'records a fresh Fedibird self-declaration without a profile or a posting grant' do
      create_node('bird.example', software: 'Fedibird', upstream: 'mastodon')
      account = remote_group('bird.example')

      result = described_class.assess(account)

      expect(result[:implementation]).to include(
        identity: 'self_declared',
        family: 'fedibird',
        software_name: 'fedibird',
        upstream_name: 'mastodon',
        fedibird_named: true,
        evidence: include(authority: 'self_declared', freshness: 'fresh', uncertainty: 'self_report', source: 'node.info')
      )
      expect(result[:profile][:kind]).to eq 'unknown'
      expect(result[:profile][:requires_mention]).to be_nil
      expect(result[:profile][:allowed_visibilities]).to be_nil
      expect(result[:compatibility_candidates]).to eq ['fedibird_nodeinfo']
      expect(result[:remote_fedibird]).to eq 'self_declared'
      expect(result[:fedibird_posting]).to eq 'withheld'
      expect(result[:authorizes_posting]).to be false
      expect(capability(result, 'requires_group_mention')).to include(state: 'unknown', value: nil)
      expect(capability(result, 'follow_as_membership')).to include(state: 'unknown', value: nil)
      expect(capability(result, 'fep_1b12_audience')).to include(state: 'unknown', value: nil)
      expect(capability(result, 'remote_posting_released')).to include(state: 'withheld', value: false)
    end

    it 'leaves a non-group on a Fedibird server out of the remote group states' do
      create_node('people.example', software: 'fedibird')
      account = Fabricate(
        :account,
        username: 'alice',
        domain: 'people.example',
        actor_type: 'Person',
        protocol: :activitypub,
        uri: 'https://people.example/users/alice'
      )

      result = described_class.assess(account)

      expect(result[:group]).to be false
      expect(result[:implementation]).to include(
        identity: 'self_declared',
        family: 'fedibird',
        software_name: 'fedibird',
        fedibird_named: false
      )
      expect(result[:profile][:kind]).to eq 'not_applicable'
      expect(result[:remote_fedibird]).to eq 'not_applicable'
      expect(result[:fedibird_posting]).to eq 'not_applicable'
      expect(result[:compatibility_candidates]).to eq []
      expect(result[:actor_capabilities]).to eq []
      expect(result[:viewer_capabilities]).to be_nil
    end

    it 'treats other exact software names as compatibility candidates, not profiles' do
      %w(mitra nodebb lemmy piefed).each do |software|
        domain = "#{software}.example"
        create_node(domain, software: software, upstream: nil)
        account = remote_group(domain, username: software)

        result = described_class.assess(account)

        expect(result[:compatibility_candidates]).to eq ["#{software}_nodeinfo"]
        expect(result[:profile][:kind]).to eq 'unknown'
        expect(result[:remote_fedibird]).to eq 'not_determined'
        expect(result[:implementation][:fedibird_named]).to be false
        expect(result[:implementation][:family]).to eq software
      end
    end

    it 'does not promote an upstream-only Fedibird name or a lookalike token' do
      create_node('fork.example', software: 'hometown', upstream: 'fedibird')
      create_node('suffix.example', software: 'fedibird-fork', upstream: 'mastodon')
      create_node('spaced.example', software: ' fedibird ', upstream: 'mastodon')

      fork_result = described_class.assess(remote_group('fork.example'))
      suffix_result = described_class.assess(remote_group('suffix.example'))
      spaced_result = described_class.assess(remote_group('spaced.example'))

      expect(fork_result[:implementation]).to include(identity: 'self_declared', family: 'other', fedibird_named: false, evidence: include(uncertainty: 'upstream_only'))
      expect(fork_result[:compatibility_candidates]).to eq []
      expect(fork_result[:remote_fedibird]).to eq 'not_determined'
      expect(suffix_result[:implementation]).to include(family: 'other', fedibird_named: false)
      expect(suffix_result[:remote_fedibird]).to eq 'not_determined'
      expect(spaced_result[:implementation][:fedibird_named]).to be true
      expect(spaced_result[:remote_fedibird]).to eq 'self_declared'
    end

    it 'ignores an admin override that disagrees with the stored NodeInfo snapshot' do
      create_node('override.example', software: 'lemmy', upstream: 'lemmy', info_override: { 'software_name' => 'fedibird' })
      create_node('kept.example', software: 'fedibird', upstream: 'mastodon', info_override: { 'software_name' => 'lemmy' })

      overridden = described_class.assess(remote_group('override.example'))
      kept = described_class.assess(remote_group('kept.example'))

      expect(overridden[:implementation]).to include(
        software_name: 'lemmy',
        fedibird_named: false,
        evidence: include(uncertainty: 'override_ignored')
      )
      expect(overridden[:compatibility_candidates]).to eq ['lemmy_nodeinfo']
      expect(overridden[:remote_fedibird]).to eq 'not_determined'
      expect(kept[:implementation]).to include(software_name: 'fedibird', fedibird_named: true, evidence: include(uncertainty: 'override_ignored'))
      expect(kept[:remote_fedibird]).to eq 'self_declared'
      expect(kept[:profile][:kind]).to eq 'unknown'
    end

    it 'drops a Fedibird name left behind after NodeInfo is missing, stale, or never fetched' do
      travel_to(Time.utc(2026, 11, 1, 12, 0, 0)) do
        missing = create_node(
          'missing.example',
          software: 'fedibird',
          nodeinfo: { 'error' => 'missing' }
        )
        stale = create_node('stale.example', software: 'fedibird', fetched_at: Time.current - 1.day)
        fresh = create_node('fresh.example', software: 'fedibird', fetched_at: Time.current - 1.day + 1.second)
        unfetched = create_node('unfetched.example', software: 'fedibird', fetched_at: nil)

        missing_result = described_class.assess(remote_group('missing.example'))
        stale_result = described_class.assess(remote_group('stale.example'))
        fresh_result = described_class.assess(remote_group('fresh.example'))
        unfetched_result = described_class.assess(remote_group('unfetched.example'))

        expect(missing_result[:implementation]).to include(identity: 'withheld', software_name: nil, fedibird_named: false, evidence: include(freshness: 'missing', uncertainty: 'nodeinfo_missing'))
        expect(missing.info['software_name']).to eq 'fedibird'
        expect(stale_result[:implementation]).to include(
          identity: 'withheld',
          software_name: 'fedibird',
          family: 'fedibird',
          fedibird_named: false,
          evidence: include(freshness: 'stale', uncertainty: 'stale')
        )
        expect(stale_result[:remote_fedibird]).to eq 'not_determined'
        expect(fresh_result[:remote_fedibird]).to eq 'self_declared'
        expect(unfetched_result[:implementation]).to include(software_name: nil, fedibird_named: false, evidence: include(freshness: 'unfetched', uncertainty: 'absent'))
      end
    end

    it 'reads a changed snapshot on the next call without keeping the previous claim' do
      travel_to(Time.utc(2026, 11, 1, 12, 0, 0)) do
        node = create_node('cache.example', software: 'fedibird', fetched_at: Time.current)
        account = remote_group('cache.example')

        expect(described_class.assess(account)[:remote_fedibird]).to eq 'self_declared'

        node.update_columns(last_fetched_at: Time.current - 1.day)
        account.association(:node).reset

        expect(described_class.assess(account)[:remote_fedibird]).to eq 'not_determined'
        expect(described_class.assess(account)[:implementation][:evidence]).to include(freshness: 'stale')

        node.update_columns(nodeinfo: { 'error' => 'missing' }, last_fetched_at: Time.current)
        account.association(:node).reset

        withheld = described_class.assess(account)
        expect(withheld[:implementation][:software_name]).to be_nil
        expect(withheld[:implementation][:evidence]).to include(uncertainty: 'nodeinfo_missing')
      end
    end

    it 'does not bind a node snapshot when the stored actor host differs, and ignores the actor text' do
      create_node('group.example', software: 'fedibird')
      mismatched = remote_group('group.example', uri: 'https://group.example@169.254.169.254/users/group', inbox_url: 'http://169.254.169.254/inbox')
      unverified = remote_group('group.example', username: 'blank', uri: '')
      unverified.update_columns(uri: '')
      labeled = remote_group('group.example', username: 'labeled')
      labeled.update_columns(display_name: 'Fedibird', note: 'https://fedibird.com/ns#MentionFollowAnnounce FEP-1b12')

      mismatch_result = described_class.assess(mismatched)
      blank_result = described_class.assess(unverified.reload)
      labeled_result = described_class.assess(labeled)

      expect(mismatch_result[:implementation]).to include(software_name: nil, fedibird_named: false, evidence: include(uncertainty: 'actor_mismatch'))
      expect(mismatch_result[:remote_fedibird]).to eq 'not_determined'
      expect(blank_result[:implementation][:evidence]).to include(uncertainty: 'actor_unverified')
      expect(labeled_result[:remote_fedibird]).to eq 'self_declared'
      expect(labeled_result[:profile][:kind]).to eq 'unknown'
    end

    it 'trusts info from the processed snapshot and does not follow a document link' do
      create_node(
        'doc.example',
        software: 'lemmy',
        upstream: 'lemmy',
        nodeinfo: { 'links' => [{ 'href' => 'http://169.254.169.254/latest' }], 'software' => { 'name' => 'fedibird' } }
      )

      result = described_class.assess(remote_group('doc.example'))

      expect(result[:implementation][:software_name]).to eq 'lemmy'
      expect(result[:remote_fedibird]).to eq 'not_determined'
      expect(result[:compatibility_candidates]).to eq ['lemmy_nodeinfo']
    end

    it 'switches a group from the local server contract to an unbound remote actor' do
      account = Fabricate(:account, username: 'switchgroup', actor_type: 'Group')
      local = described_class.assess(account)

      account.update_columns(
        domain: 'switched.example',
        uri: 'https://switched.example/users/switchgroup',
        inbox_url: 'https://switched.example/inbox',
        protocol: Account.protocols[:activitypub]
      )
      remote = described_class.assess(account.reload)

      create_node('switched.example', software: 'fedibird')
      declared = described_class.assess(account.reload)

      expect(local[:fedibird_posting]).to eq 'server_local'
      expect(local[:profile][:kind]).to eq 'fedibird_mention_follow_announce'
      expect(remote[:fedibird_posting]).to eq 'withheld'
      expect(remote[:profile][:kind]).to eq 'unknown'
      expect(remote[:remote_fedibird]).to eq 'not_determined'
      expect(declared[:remote_fedibird]).to eq 'self_declared'
      expect(declared[:fedibird_posting]).to eq 'withheld'
      expect(declared[:authorizes_posting]).to be false
    end

    it 'rejects the future determined state' do
      account = Fabricate(:account, username: 'group', actor_type: 'Group')
      bad = described_class.assess(account).merge(remote_fedibird: described_class::FUTURE_REMOTE_FEDIBIRD_DETERMINED)

      expect { described_class::Contract.assert!(bad) }.to raise_error(described_class::ContractError, 'determined remote')
    end

    it 'rejects a posting or remote state that does not match the actor' do
      local = described_class.assess(Fabricate(:account, username: 'shapegroup', actor_type: 'Group'))
      remote = described_class.assess(remote_group('shape.example'))
      person = described_class.assess(Fabricate(:account, username: 'shapeperson'))

      expect { described_class::Contract.assert!(local.merge(fedibird_posting: 'not_applicable')) }.to raise_error(described_class::ContractError, 'posting shape')
      expect { described_class::Contract.assert!(local.merge(fedibird_posting: 'withheld')) }.to raise_error(described_class::ContractError, 'posting shape')
      expect { described_class::Contract.assert!(local.merge(remote_fedibird: 'not_determined')) }.to raise_error(described_class::ContractError, 'remote shape')
      expect { described_class::Contract.assert!(remote.merge(fedibird_posting: 'server_local')) }.to raise_error(described_class::ContractError, 'posting shape')
      expect { described_class::Contract.assert!(remote.merge(fedibird_posting: 'not_applicable')) }.to raise_error(described_class::ContractError, 'posting shape')
      expect { described_class::Contract.assert!(remote.merge(remote_fedibird: 'not_applicable')) }.to raise_error(described_class::ContractError, 'remote shape')
      expect { described_class::Contract.assert!(person.merge(fedibird_posting: 'withheld')) }.to raise_error(described_class::ContractError, 'posting shape')
      expect { described_class::Contract.assert!(person.merge(remote_fedibird: 'self_declared')) }.to raise_error(described_class::ContractError, 'named remote')
    end
  end

  describe 'viewer capabilities' do # rubocop:disable Metrics/BlockLength
    let(:viewer) { Fabricate(:account, username: 'alice') }

    it 'observes a local follow and a role without turning either into can_post' do
      requester = Fabricate(:user)
      request = GroupCreationRequest.create!(
        requester_account: requester.account,
        username: "role#{SecureRandom.hex(3)}",
        display_name: 'Role Group',
        note: 'local'
      )
      group = Fabricate(:account, username: request.username, actor_type: 'Group')
      ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request)
      GroupRoleAssignment.create!(
        group_account: group,
        member_account: requester.account,
        role: :owner,
        granted_at: Time.current
      )
      moderator = Fabricate(:user)
      GroupRoleAssignment.create!(
        group_account: group,
        member_account: moderator.account,
        role: :moderator,
        granted_at: Time.current
      ).revoke!
      pending_account = Fabricate(:account, username: 'pending')
      Fabricate(:follow, account: viewer, target_account: group)
      Fabricate(:follow_request, account: pending_account, target_account: group)

      owner = described_class.assess(group, viewer: requester.account)
      former = described_class.assess(group, viewer: moderator.account)
      member = described_class.assess(group, viewer: viewer)
      pending = described_class.assess(group, viewer: pending_account)
      stranger = described_class.assess(group, viewer: Fabricate(:account, username: 'stranger'))

      expect(capability(owner, 'role', scope: :viewer)).to include(state: 'observed', value: 'owner')
      expect(capability(owner, 'membership_follow', scope: :viewer)).to include(state: 'denied', value: false)
      expect(capability(former, 'role', scope: :viewer)).to include(state: 'denied', value: 'none')
      expect(capability(member, 'membership_follow', scope: :viewer)).to include(state: 'observed', value: true, evidence: include(source: 'local_follow', authority: 'server'))
      expect(capability(member, 'role', scope: :viewer)).to include(state: 'denied', value: 'none')
      expect(capability(pending, 'membership_follow', scope: :viewer)).to include(state: 'denied', value: false)
      expect(capability(stranger, 'membership_follow', scope: :viewer)).to include(state: 'denied', value: false)
      [owner, former, member, pending, stranger].each do |result|
        expect(capability(result, 'can_post', scope: :viewer)).to include(state: 'unknown', value: nil, evidence: include(uncertainty: 'not_a_grant'))
        expect(result[:authorizes_posting]).to be false
        expect(result[:fedibird_posting]).to eq 'server_local'
      end
    end

    it 'keeps a fresh FEP-5219 create grant from becoming a role or a Fedibird post' do
      create_node('aff.example', software: 'fedibird')
      group = remote_group('aff.example')
      viewer_uri = ActivityPub::TagManager.instance.uri_for(viewer)
      group.update_columns(
        affiliations_fetched_at: Time.current,
        permission_definitions_fetched_at: Time.current,
        can_create_affiliation: 'none',
        can_view_affiliation: 'member'
      )
      GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'owner', affiliation_uri: 'https://aff.example/rel/1')
      Fabricate(:follow, account: viewer, target_account: group)

      result = described_class.assess(group, viewer: viewer)

      expect(capability(result, 'fep_5219_can_create', scope: :viewer)).to include(state: 'observed', value: true, evidence: include(source: 'fep-5219', authority: 'protocol', freshness: 'fresh'))
      expect(capability(result, 'fep_5219_can_view', scope: :viewer)).to include(state: 'unknown', value: nil, evidence: include(freshness: 'fresh', uncertainty: 'none'))
      expect(capability(result, 'role', scope: :viewer)).to include(state: 'unknown', value: nil, evidence: include(uncertainty: 'not_a_role'))
      expect(capability(result, 'membership_follow', scope: :viewer)).to include(state: 'unknown', value: nil)
      expect(capability(result, 'can_post', scope: :viewer)).to include(state: 'unknown', value: nil)
      expect(result[:authorizes_posting]).to be false
      expect(result[:profile][:kind]).to eq 'unknown'
      expect(result.to_json).not_to include('owner')
      expect(result.to_json).not_to include(viewer_uri)
    end

    it 'treats a stale or unfetched permission snapshot as unknown rather than a denial' do
      travel_to(Time.utc(2026, 11, 1, 12, 0, 0)) do
        group = remote_group('stale-aff.example')
        viewer_uri = ActivityPub::TagManager.instance.uri_for(viewer)
        group.update_columns(
          affiliations_url: 'https://stale-aff.example/affiliations',
          affiliations_fetched_at: Time.current,
          permission_definitions_fetched_at: Time.current,
          can_create_affiliation: 'trusted-poster'
        )
        GroupAffiliation.create!(group_account: group, subject_uri: viewer_uri, relationship: 'trusted-poster')

        fresh = described_class.assess(group, viewer: viewer)
        expect(capability(fresh, 'fep_5219_can_create', scope: :viewer)).to include(state: 'observed', value: true)

        group.update_columns(affiliations_fetched_at: Time.current - 1.day)
        stale = described_class.assess(group.reload, viewer: viewer)
        expect(capability(stale, 'fep_5219_can_create', scope: :viewer)).to include(state: 'unknown', value: nil, evidence: include(freshness: 'stale', uncertainty: 'stale'))

        group.update_columns(affiliations_fetched_at: nil, permission_definitions_fetched_at: nil, can_create_affiliation: 'trusted-poster')
        unfetched = described_class.assess(group.reload, viewer: viewer)
        expect(capability(unfetched, 'fep_5219_can_create', scope: :viewer)).to include(state: 'unfetched', value: nil)
        expect(capability(unfetched, 'can_post', scope: :viewer)[:state]).to eq 'unknown'
      end
    end

    it 'keeps an observed FEP allow fresh only while the resolver may allow that snapshot' do
      travel_to(Time.utc(2026, 11, 1, 12, 0, 0)) do
        group = remote_group('none-aff.example')
        group.update_columns(
          affiliations_url: 'https://none-aff.example/affiliations',
          affiliations_fetched_at: Time.current - 1.day,
          permission_definitions_fetched_at: Time.current,
          can_create_affiliation: 'none'
        )

        observed = described_class.assess(group, viewer: viewer)
        expect(capability(observed, 'fep_5219_can_create', scope: :viewer)).to include(state: 'observed', value: true, evidence: include(freshness: 'fresh'))

        group.update_columns(permission_definitions_fetched_at: Time.current - 1.day)
        stale_definition = described_class.assess(group.reload, viewer: viewer)
        expect(capability(stale_definition, 'fep_5219_can_create', scope: :viewer)).to include(state: 'unknown', value: nil, evidence: include(freshness: 'stale', uncertainty: 'stale'))

        group.update_columns(permission_definitions_fetched_at: nil, affiliations_fetched_at: nil)
        unfetched_definition = described_class.assess(group.reload, viewer: viewer)
        expect(capability(unfetched_definition, 'fep_5219_can_create', scope: :viewer)).to include(state: 'unfetched', value: nil, evidence: include(freshness: 'unfetched'))
      end
    end

    it 'rejects an allowed FEP decision when the snapshot the resolver requires is not fresh' do
      group = remote_group('guard-aff.example')
      group.update_columns(
        affiliations_url: 'https://guard-aff.example/affiliations',
        affiliations_fetched_at: nil,
        permission_definitions_fetched_at: nil,
        can_create_affiliation: 'none'
      )
      resolver = instance_double(PostingContext::GroupPermissionEvidenceResolver)
      allow(PostingContext::GroupPermissionEvidenceResolver).to receive(:new).and_return(resolver)
      allow(resolver).to receive(:call).and_return(
        create: { status: 'allowed', via_relationship: 'none', source: 'fep-5219', authority: 'protocol' },
        view: { status: 'unknown', via_relationship: nil, source: 'fep-5219', authority: 'protocol' }
      )

      expect { described_class.assess(group, viewer: viewer) }.to raise_error(described_class::ContractError, 'stale fep allow')

      group.update_columns(permission_definitions_fetched_at: Time.current, can_create_affiliation: 'member')
      allow(resolver).to receive(:call).and_return(
        create: { status: 'allowed', via_relationship: 'member', source: 'fep-5219', authority: 'protocol' },
        view: { status: 'unknown', via_relationship: nil, source: 'fep-5219', authority: 'protocol' }
      )

      expect { described_class.assess(group.reload, viewer: viewer) }.to raise_error(described_class::ContractError, 'stale fep allow')
    end
  end

  describe '.public_metadata' do
    it 'omits viewer affiliation, follow, and role from the directory view' do
      requester = Fabricate(:user)
      request = GroupCreationRequest.create!(
        requester_account: requester.account,
        username: "pub#{SecureRandom.hex(3)}",
        display_name: 'Public Group',
        note: 'local'
      )
      group = Fabricate(:account, username: request.username, actor_type: 'Group')
      ManagedGroup.create!(account: group, origin: :approved_request, creation_request: request)
      GroupRoleAssignment.create!(group_account: group, member_account: requester.account, role: :owner, granted_at: Time.current)
      Fabricate(:follow, account: requester.account, target_account: group)

      full = described_class.assess(group, viewer: requester.account)
      public_view = described_class.public_metadata(group)

      expect(public_view.keys).to eq described_class::PUBLIC_KEYS
      expect(public_view).not_to have_key(:viewer_capabilities)
      expect(public_view).to eq full.slice(*described_class::PUBLIC_KEYS)
      expect(public_view.to_json).not_to include('owner')
      expect(public_view.to_json).not_to include(requester.account.username)
      expect(full[:viewer_capabilities].map { |row| row[:name] }).to eq described_class::VIEWER_CAPABILITIES
    end
  end

  describe 'posting context boundary' do
    it 'does not open the Fedibird composer for a self-declared remote group' do
      create_node('composer.example', software: 'fedibird', upstream: 'mastodon')
      remote = remote_group('composer.example')
      local = Fabricate(:account, username: 'localgroup', actor_type: 'Group')

      expect(PostingContext::Adapters::FedibirdGroup.applicable?(remote)).to be false
      expect(PostingContext::Adapters::FedibirdGroup.applicable?(local)).to be true
      expect(PostingIdentity::RemoteGroupPost::SUPPORTED_ADAPTERS).not_to include('fedibird_group')

      remote_discovery = PostingContext::DiscoveryService.new.call(remote)
      local_discovery = PostingContext::DiscoveryService.new.call(local)

      expect(remote_discovery).to include(status: 'unsupported', reason: 'no_supported_adapter', context: nil, viewer_evidence: nil)
      expect(remote_discovery[:discovery]).to eq(mechanism: nil, adapter: nil, authority: nil)
      expect(local_discovery).to include(
        status: 'resolved',
        discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' }
      )
      expect(described_class.assess(local)[:remote_posting_released]).to be_nil
      expect(capability(described_class.assess(local), 'remote_posting_released')[:value]).to be false
    end

    it 'leaves an existing Mitra NodeInfo adapter in place while the profile stays unknown' do
      create_node('mitra-boundary.example', software: 'mitra', upstream: nil)
      account = remote_group('mitra-boundary.example')

      discovered = PostingContext::DiscoveryService.new.call(account)
      assessed = described_class.assess(account)

      expect(discovered.dig(:discovery, :adapter)).to eq 'mitra_group'
      expect(discovered.dig(:discovery, :authority)).to eq 'compatibility'
      expect(discovered[:status]).to eq 'resolved'
      expect(assessed[:profile][:kind]).to eq 'unknown'
      expect(assessed[:compatibility_candidates]).to eq ['mitra_nodeinfo']
      expect(assessed[:authorizes_posting]).to be false
    end

    it 'does not consult an explicit protocol feature in this phase' do
      create_node('feature.example', software: 'mastodon', upstream: 'mastodon')
      account = remote_group('feature.example')
      expect(described_class).not_to receive(:explicit_protocol_feature)

      result = described_class.assess(account)

      expect(result[:profile][:kind]).to eq 'unknown'
      expect(result[:remote_fedibird]).to eq 'not_determined'
      expect(result[:fedibird_posting]).to eq 'withheld'
      expect(PostingContext::Adapters::FedibirdGroup.applicable?(account)).to be false
    end
  end
end
