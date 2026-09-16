# frozen_string_literal: true

require 'rails_helper'

RSpec.describe FollowImport::RemoteAdmission do
  def profile(**caps)
    FollowImport::RemoteAdmissionProfile.parse(
      {
        version: 1,
        destination: { per_tick_cap: caps.fetch(:destination, 2) },
        origin: { per_tick_cap: caps.fetch(:origin, 2) },
        runtime: {
          mapping_ttl_seconds: 3600,
          max_retry_after_seconds: 120,
          recent_429_cooldown_seconds: 30,
        },
        scan: { max_targets_per_batch: 20, max_windows_per_batch: 4 },
      }
    )
  end

  def runtime(mappings: {}, suppressions: {}, available: true)
    state = Object.new
    state.define_singleton_method(:available?) { available }
    state.define_singleton_method(:mapping_for) do |domain|
      origin = mappings[domain]
      next if origin.blank?

      FollowImport::RemoteRuntimeState::Mapping.new(endpoint_origin: origin, observed_at: Time.now.utc)
    end
    state.define_singleton_method(:suppression_for) { |origin| suppressions[origin] }
    state
  end

  def admission(profile: self.profile, mappings: {}, suppressions: {}, hosts: [], hosts_ok: true, available: true)
    described_class.new(
      profile: profile,
      runtime: runtime(mappings: mappings, suppressions: suppressions, available: available),
      unavailable_hosts: hosts.to_set,
      unavailable_snapshot_available: hosts_ok
    )
  end

  def decide_and_maybe_admit(policy, domain)
    decision = policy.decide(destination_domain: domain)
    policy.record_admit(decision) if decision.admit?
    decision
  end

  it 'does not consume remote caps for local destinations' do
    local = TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
    policy = admission(profile: profile(destination: 1))

    local_decision = decide_and_maybe_admit(policy, local)
    remote_decision = decide_and_maybe_admit(policy, 'remote.example')
    second_remote = policy.decide(destination_domain: 'remote.example')

    expect(local_decision.admit?).to be true
    expect(local_decision.reason).to eq 'local_destination'
    expect(remote_decision.admit?).to be true
    expect(second_remote.admit?).to be false
    expect(second_remote.reason).to eq 'destination_cap'
    expect(policy.planned_by_destination[local]).to eq 0
  end

  it 'treats an explicit local-domain acct the same as a bare local acct' do
    local = TagManager.instance.normalize_domain(Rails.configuration.x.local_domain)
    policy = admission

    expect(policy.decide(destination_domain: local).reason).to eq 'local_destination'
  end

  it 'uses a synthetic unknown bucket for missing destination_domain' do
    policy = admission(profile: profile(destination: 1))

    first = decide_and_maybe_admit(policy, nil)
    second = policy.decide(destination_domain: nil)

    expect(first.admit?).to be true
    expect(first.reason).to eq 'admitted'
    expect(first.reasons).to include('missing_destination')
    expect(first.routing_key).to eq described_class::UNKNOWN_DESTINATION
    expect(second.admit?).to be false
    expect(second.reason).to eq 'destination_cap'
  end

  it 'does not persist the synthetic unknown destination onto the candidate' do
    policy = admission
    decision = policy.decide(destination_domain: nil)

    expect(decision.destination_domain).to be_nil
    expect(decision.routing_key).to eq described_class::UNKNOWN_DESTINATION
  end

  it 'blocks an exact UnavailableDomain destination host and not an unrelated host' do
    policy = admission(hosts: ['dead.example'])

    expect(policy.decide(destination_domain: 'dead.example').reason).to eq 'unavailable_destination'
    expect(policy.decide(destination_domain: 'social.example').admit?).to be true
  end

  it 'blocks a mapped origin whose host exactly matches UnavailableDomain' do
    policy = admission(
      mappings: { 'social.example' => 'https://shared-dead.example' },
      hosts: ['shared-dead.example']
    )

    expect(policy.decide(destination_domain: 'social.example').reason).to eq 'unavailable_origin'
  end

  it 'does not infer an inbox host from the acct domain' do
    policy = admission(hosts: ['social.example'])

    expect(policy.decide(destination_domain: 'other.example').admit?).to be true
  end

  it 'honors Retry-After suppression on a mapped origin' do
    suppression = FollowImport::RemoteRuntimeState::Suppression.new(
      honor_until: 2.minutes.from_now,
      reason: 'retry_after',
      observed_at: Time.now.utc
    )
    policy = admission(
      mappings: { 'remote.example' => 'https://shared.example' },
      suppressions: { 'https://shared.example' => suppression }
    )

    expect(policy.decide(destination_domain: 'remote.example').reason).to eq 'retry_after'
  end

  it 'honors a configured recent-429 cooldown' do
    suppression = FollowImport::RemoteRuntimeState::Suppression.new(
      honor_until: 30.seconds.from_now,
      reason: 'recent_429',
      observed_at: Time.now.utc
    )
    policy = admission(
      mappings: { 'remote.example' => 'https://shared.example' },
      suppressions: { 'https://shared.example' => suppression }
    )

    expect(policy.decide(destination_domain: 'remote.example').reason).to eq 'recent_429'
  end

  it 'records runtime_state_unavailable on the candidate whose lookup failed' do
    failed = false
    runtime = Object.new
    runtime.define_singleton_method(:available?) { !failed }
    runtime.define_singleton_method(:mapping_for) do |_domain|
      failed = true
      nil
    end
    runtime.define_singleton_method(:suppression_for) { |_origin| nil }
    policy = described_class.new(
      profile: profile,
      runtime: runtime,
      unavailable_hosts: Set.new,
      unavailable_snapshot_available: true
    )

    decision = policy.decide(destination_domain: 'remote.example')

    expect(decision.admit?).to be true
    expect(decision.runtime_state_source).to eq 'unavailable'
    expect(decision.reasons).to include('runtime_state_unavailable')
  end

  it 'falls back to destination cap only when runtime state is unavailable' do
    policy = admission(profile: profile(destination: 1), available: false)

    first = decide_and_maybe_admit(policy, 'remote.example')
    second = policy.decide(destination_domain: 'remote.example')

    expect(first.admit?).to be true
    expect(first.reasons).to include('runtime_state_unavailable')
    expect(second.reason).to eq 'destination_cap'
    expect(policy.planned_by_origin).to be_empty
  end

  it 'does not consult Accept, Reject, Follow Gate, or moderation inputs' do
    allow(Follow).to receive(:exists?)
    allow(FollowRequest).to receive(:exists?)
    allow(FollowImport::ExecutionGate).to receive(:for_account)
    policy = admission

    policy.decide(destination_domain: 'remote.example')

    expect(Follow).not_to have_received(:exists?)
    expect(FollowRequest).not_to have_received(:exists?)
    expect(FollowImport::ExecutionGate).not_to have_received(:for_account)
  end
end
