# frozen_string_literal: true

require 'rails_helper'

# rubocop:disable Metrics/BlockLength
RSpec.describe Moderation::FollowRejectObservationService do
  subject(:service) { described_class.new }

  let(:now) { Time.utc(2026, 6, 1, 12, 0, 0) }
  let(:actor) { Fabricate(:account, username: 'reject_subject') }

  def reject_from(rejector, latency:, at:, key:)
    Moderation::EventRecorder.new.record_interaction(
      actor: actor,
      target: rejector,
      event_type: :follow,
      occurred_at: at - latency,
      source_event_key: "#{key}-contact"
    )
    Moderation::EventRecorder.new.record_rejection(
      rejector: rejector,
      rejected: actor,
      event_type: :follow_reject,
      occurred_at: at,
      source_event_key: "#{key}-reject"
    )
  end

  def raw_reject_from(rejector, at:, key:)
    Moderation::EventRecorder.new.record_rejection(
      rejector: rejector,
      rejected: actor,
      event_type: :follow_reject,
      occurred_at: at,
      source_event_key: key
    )
  end

  def window(result, name = '1h')
    result.dig('windows', name)
  end

  def mutation_counts
    {
      subjects: ModerationSubject.count,
      interactions: ModerationInteractionEvent.count,
      rejections: ModerationRejectionEvent.count,
      actions: ModerationAction.count,
      snapshots: ModerationEvidenceSnapshot.count,
      follows: Follow.count,
      blocks: Block.count,
      mutes: Mute.count,
    }
  end

  def scalar_values(value, found = [])
    case value
    when Hash
      value.each do |key, child|
        found << key.to_s
        scalar_values(child, found)
      end
    when Array
      value.each { |child| scalar_values(child, found) }
    else
      found << value
    end
    found
  end

  def expect_zero_counts(report)
    expect(report['raw_follow_reject_events']).to eq 0
    expect(report['qualified_follow_reject_events']).to eq 0
    expect(report['unqualified_follow_reject_events']).to eq 0
    expect(report['qualified_unique_responders']).to eq 0
    expect(report['latency_buckets']).to eq(
      'lte_5s' => 0,
      'gt_5s_lte_30s' => 0,
      'gt_30s_lte_5m' => 0,
      'gt_5m' => 0,
      'unknown' => 0
    )
    expect(report['immediate_lte_5s_events']).to eq 0
    expect(report.dig('actor_types', 'event_counts').keys).to eq described_class::ACTOR_TYPE_KEYS
    expect(report.dig('actor_types', 'unique_responder_counts').keys).to eq described_class::ACTOR_TYPE_KEYS
    expect(report.dig('actor_types', 'event_counts').values).to all(eq(0))
    expect(report.dig('actor_types', 'unique_responder_counts').values).to all(eq(0))
    expect(report['bot_like_events']).to eq 0
    expect(report['bot_like_unique_responders']).to eq 0
    expect(report['immediate_lte_5s_bot_like_events']).to eq 0
    expect(report['immediate_lte_5s_bot_like_unique_responders']).to eq 0
    expect(report['current_actor_metadata_known_unique_responders']).to eq 0
    expect(report['current_actor_metadata_unknown_unique_responders']).to eq 0
    expect(report['unique_responder_domains']).to eq 0
    expect(report['largest_domain_responder_count']).to eq 0
    expect(report['largest_domain_responder_share']).to eq 0.0
    expect(report['local_unique_responders']).to eq 0
    expect(report['unknown_domain_unique_responders']).to eq 0
  end

  describe 'stable empty shape' do
    it 'returns every window and zero counts when the account has no subject' do
      fresh = Fabricate(:account, username: 'never_observed')
      result = nil

      expect { result = service.call(fresh, now: now) }.to_not change(ModerationSubject, :count)

      expect(result['generated_at']).to eq now.iso8601
      expect(result['windows'].keys).to eq %w(1h 24h 7d)
      expect(result['notes']).to include(
        'latency buckets are descriptive and do not classify a rejection as automated or human',
        'actor type and bot-like metadata are current Account attributes, not event-time historical snapshots',
        'Service/Application metadata does not prove automation or malicious behavior',
        'domain concentration does not prove coordination',
        'absence of observed negatives is not evidence of absence'
      )
      result['windows'].each_value { |report| expect_zero_counts(report) }
    end

    it 'returns the same empty shape for nil and for a subject with no Follow Rejects' do
      subject_row = Fabricate(:moderation_subject, account: actor)

      expect_zero_counts(window(service.call(nil, now: now)))
      expect_zero_counts(window(service.call(subject_row, now: now)))
      expect(ModerationSubject.where(account_id: actor.id).count).to eq 1
    end
  end

  describe 'latency boundaries' do
    before do
      {
        'zero' => 0,
        'five' => 5,
        'over_five' => 5.01,
        'thirty' => 30,
        'over_thirty' => 30.01,
        'five_min' => 300,
        'over_five_min' => 300.01,
      }.each do |name, latency|
        # One rejector per sample, so the recorder links the contact this
        # example created rather than a nearer contact from another sample.
        reject_from(Fabricate(:account, username: "latency_#{name}"), latency: latency, at: now - 1.minute, key: "latency-#{name}")
      end
    end

    it 'assigns the inclusive boundaries and keeps unknown at zero' do
      buckets = window(service.call(actor, now: now))['latency_buckets']

      expect(buckets).to eq(
        'lte_5s' => 2,
        'gt_5s_lte_30s' => 2,
        'gt_30s_lte_5m' => 2,
        'gt_5m' => 1,
        'unknown' => 0
      )
    end

    it 'counts immediate_lte_5s_events as the lte_5s bucket' do
      report = window(service.call(actor, now: now))

      expect(report['immediate_lte_5s_events']).to eq 2
      expect(report['immediate_lte_5s_events']).to eq report.dig('latency_buckets', 'lte_5s')
      expect(report['qualified_follow_reject_events']).to eq 7
    end
  end

  describe 'unusable latency' do
    before do
      reject_from(Fabricate(:account, username: 'unusable_rejector'), latency: 1, at: now - 1.minute, key: 'unusable')
    end

    it 'keeps a nil time_to_rejection in unknown without dropping the qualified event' do
      allow_any_instance_of(ModerationRejectionEvent).to receive(:time_to_rejection).and_return(nil)
      report = window(service.call(actor, now: now))

      expect(report['qualified_follow_reject_events']).to eq 1
      expect(report.dig('latency_buckets', 'unknown')).to eq 1
      expect(report['immediate_lte_5s_events']).to eq 0
    end

    it 'keeps a negative time_to_rejection in unknown' do
      allow_any_instance_of(ModerationRejectionEvent).to receive(:time_to_rejection).and_return(-1)
      report = window(service.call(actor, now: now))

      expect(report.dig('latency_buckets', 'unknown')).to eq 1
      expect(report.dig('latency_buckets', 'lte_5s')).to eq 0
    end
  end

  describe 'qualification' do
    let(:linked) { Fabricate(:account, username: 'linked_person', actor_type: 'Person') }
    let(:synthetic) { Fabricate(:account, username: 'synthetic_service', domain: 'synthetic.example', actor_type: 'Service') }

    before do
      reject_from(linked, latency: 10, at: now - 5.minutes, key: 'qualified')
      raw_reject_from(synthetic, at: now - 4.minutes, key: 'synthetic-reject')
      Moderation::EventRecorder.new.record_interaction(
        actor: actor, target: linked, event_type: :follow, occurred_at: now - 3.minutes, source_event_key: 'block-contact'
      )
      Moderation::EventRecorder.new.record_rejection(
        rejector: linked, rejected: actor, event_type: :block, occurred_at: now - 2.minutes, source_event_key: 'block-reject'
      )
    end

    it 'counts an unlinked Follow Reject as raw only and ignores other rejection types' do
      report = window(service.call(actor, now: now))

      expect(report['raw_follow_reject_events']).to eq 2
      expect(report['qualified_follow_reject_events']).to eq 1
      expect(report['unqualified_follow_reject_events']).to eq 1
      expect(report['qualified_unique_responders']).to eq 1
      expect(report.dig('latency_buckets', 'gt_5s_lte_30s')).to eq 1
      expect(report['latency_buckets'].values.sum).to eq 1
      expect(report['bot_like_events']).to eq 0
      expect(report.dig('actor_types', 'event_counts', 'Service')).to eq 0
      expect(report.dig('actor_types', 'event_counts', 'Person')).to eq 1
    end
  end

  describe 'actor type' do
    let(:detached) { Fabricate(:account, username: 'detached_actor', domain: 'detached.example', actor_type: 'Person') }

    before do
      {
        'blank' => Fabricate(:account, username: 'blank_type', actor_type: nil),
        'empty' => Fabricate(:account, username: 'empty_type', actor_type: ''),
        'person' => Fabricate(:account, username: 'person_type', actor_type: 'Person'),
        'service' => Fabricate(:account, username: 'service_type', domain: 'service.example', actor_type: 'Service'),
        'application' => Fabricate(:account, username: 'application_type', domain: 'application.example', actor_type: 'Application'),
        'group' => Fabricate(:account, username: 'group_type', domain: 'group.example', actor_type: 'Group'),
        'organization' => Fabricate(:account, username: 'organization_type', domain: 'organization.example', actor_type: 'Organization'),
        'other' => Fabricate(:account, username: 'other_type', domain: 'other.example', actor_type: 'Tombstone'),
        'detached' => detached,
      }.each do |name, rejector|
        reject_from(rejector, latency: 60, at: now - 10.minutes, key: "actor-#{name}")
      end
      ModerationSubject.find_by!(account_id: detached.id).update!(account_id: nil)
    end

    it 'buckets blank as Person, unrecognized as Other, and a detached Account as unknown' do
      report = window(service.call(actor, now: now))
      expected = {
        'Person' => 3,
        'Service' => 1,
        'Application' => 1,
        'Group' => 1,
        'Organization' => 1,
        'Other' => 1,
        'unknown' => 1,
      }

      expect(report.dig('actor_types', 'event_counts')).to eq expected
      expect(report.dig('actor_types', 'unique_responder_counts')).to eq expected
      expect(report['current_actor_metadata_known_unique_responders']).to eq 8
      expect(report['current_actor_metadata_unknown_unique_responders']).to eq 1
      expect(scalar_values(report)).to_not include('Tombstone')
    end
  end

  describe 'bot-like metadata' do
    let(:service_actor) { Fabricate(:account, username: 'bot_service', domain: 'bots.example', actor_type: 'Service') }
    let(:application_actor) { Fabricate(:account, username: 'bot_application', domain: 'apps.example', actor_type: 'Application') }
    let(:person) { Fabricate(:account, username: 'human_person', actor_type: 'Person') }

    before do
      reject_from(service_actor, latency: 1, at: now - 4.minutes, key: 'service-fast')
      reject_from(service_actor, latency: 60, at: now - 3.minutes, key: 'service-slow')
      reject_from(application_actor, latency: 10, at: now - 2.minutes, key: 'application')
      reject_from(person, latency: 1, at: now - 1.minute, key: 'person-fast')
    end

    it 'counts current Account#bot? rows without treating a fast Person reject as bot-like' do
      report = window(service.call(actor, now: now))

      expect(service_actor.bot?).to be true
      expect(application_actor.bot?).to be true
      expect(person.bot?).to be false
      expect(report['qualified_follow_reject_events']).to eq 4
      expect(report['qualified_unique_responders']).to eq 3
      expect(report['bot_like_events']).to eq 3
      expect(report['bot_like_unique_responders']).to eq 2
      expect(report['immediate_lte_5s_events']).to eq 2
      expect(report['immediate_lte_5s_bot_like_events']).to eq 1
      expect(report['immediate_lte_5s_bot_like_unique_responders']).to eq 1
      expect(report.dig('actor_types', 'event_counts', 'Service')).to eq 2
      expect(report.dig('actor_types', 'unique_responder_counts', 'Service')).to eq 1
    end
  end

  describe 'domain concentration' do
    before do
      3.times do |index|
        reject_from(
          Fabricate(:account, username: "alpha_#{index}", domain: 'alpha.example', actor_type: 'Person'),
          latency: 20,
          at: now - (index + 1).minutes,
          key: "alpha-#{index}"
        )
      end
      reject_from(
        Fabricate(:account, username: 'beta_one', domain: 'beta.example', actor_type: 'Person'),
        latency: 20,
        at: now - 10.minutes,
        key: 'beta'
      )
      reject_from(
        Fabricate(:account, username: 'local_one', actor_type: 'Person'),
        latency: 20,
        at: now - 11.minutes,
        key: 'local'
      )
    end

    it 'measures unique rejectors, counts local as one group, and hides domain names' do
      report = window(service.call(actor, now: now))
      rendered = scalar_values(report).map(&:to_s)

      expect(report['qualified_unique_responders']).to eq 5
      expect(report['unique_responder_domains']).to eq 3
      expect(report['largest_domain_responder_count']).to eq 3
      expect(report['largest_domain_responder_share']).to eq 0.6
      expect(report['local_unique_responders']).to eq 1
      expect(report['unknown_domain_unique_responders']).to eq 0
      expect(rendered).to_not include('alpha.example', 'beta.example')
      expect(rendered.join(' ')).to_not include('alpha_', 'beta_one', 'local_one')
    end

    it 'does not let a second event from one rejector inflate the domain count' do
      reject_from(
        Account.find_by!(username: 'alpha_0'),
        latency: 40,
        at: now - 12.minutes,
        key: 'alpha-repeat'
      )
      report = window(service.call(actor, now: now))

      expect(report['qualified_follow_reject_events']).to eq 6
      expect(report['qualified_unique_responders']).to eq 5
      expect(report['largest_domain_responder_count']).to eq 3
      expect(report['largest_domain_responder_share']).to eq 0.6
    end
  end

  describe 'unknown and normalized domains' do
    it 'does not treat a missing remote domain as its own shared domain' do
      remote = Fabricate(:account, username: 'no_domain', domain: 'temporary.example', actor_type: 'Person')
      reject_from(remote, latency: 15, at: now - 5.minutes, key: 'no-domain')
      ModerationSubject.find_by!(account_id: remote.id).update!(domain: '  ')

      report = window(service.call(actor, now: now))

      expect(report['qualified_unique_responders']).to eq 1
      expect(report['unique_responder_domains']).to eq 0
      expect(report['largest_domain_responder_count']).to eq 0
      expect(report['largest_domain_responder_share']).to eq 0.0
      expect(report['unknown_domain_unique_responders']).to eq 1
      expect(report['local_unique_responders']).to eq 0
      expect(scalar_values(report).map(&:to_s)).to_not include('temporary.example')
    end

    it 'groups retained domains case-insensitively and keeps a local subject local' do
      upper = Fabricate(:account, username: 'upper_host', domain: 'kept.example', actor_type: 'Person')
      lower = Fabricate(:account, username: 'lower_host', domain: 'other.example', actor_type: 'Person')
      local = Fabricate(:account, username: 'local_host', actor_type: 'Person')
      reject_from(upper, latency: 15, at: now - 5.minutes, key: 'upper')
      reject_from(lower, latency: 15, at: now - 4.minutes, key: 'lower')
      reject_from(local, latency: 15, at: now - 3.minutes, key: 'local-marked')
      ModerationSubject.find_by!(account_id: upper.id).update!(domain: 'Mix.Example')
      ModerationSubject.find_by!(account_id: lower.id).update!(domain: 'mix.example')
      ModerationSubject.find_by!(account_id: local.id).update!(domain: 'should-not-split.example')

      report = window(service.call(actor, now: now))
      rendered = scalar_values(report).map(&:to_s)

      expect(report['qualified_unique_responders']).to eq 3
      expect(report['unique_responder_domains']).to eq 2
      expect(report['largest_domain_responder_count']).to eq 2
      expect(report['largest_domain_responder_share']).to eq 2.0 / 3
      expect(report['local_unique_responders']).to eq 1
      expect(rendered).to_not include('Mix.Example', 'mix.example', 'should-not-split.example')
    end
  end

  describe 'time windows' do
    before do
      reject_from(Fabricate(:account, username: 'within_hour'), latency: 5, at: now - 10.minutes, key: 'in-1h')
      reject_from(Fabricate(:account, username: 'within_day'), latency: 5, at: now - 2.hours, key: 'in-24h')
      reject_from(Fabricate(:account, username: 'within_week'), latency: 5, at: now - 2.days, key: 'in-7d')
      reject_from(Fabricate(:account, username: 'outside_week'), latency: 5, at: now - 8.days, key: 'outside')
    end

    it 'nests 1h inside 24h inside 7d and drops anything older than 7d' do
      result = service.call(actor, now: now)

      expect(window(result, '1h')['qualified_follow_reject_events']).to eq 1
      expect(window(result, '24h')['qualified_follow_reject_events']).to eq 2
      expect(window(result, '7d')['qualified_follow_reject_events']).to eq 3
      expect(window(result, '1h')['window_start']).to eq (now - 1.hour).iso8601
      expect(window(result, '1h')['window_end']).to eq now.iso8601
    end

    it 'includes an event exactly at a window boundary and excludes the second before it' do
      reject_from(Fabricate(:account, username: 'edge_hour'), latency: 1, at: now - 1.hour, key: 'edge-1h')
      reject_from(Fabricate(:account, username: 'before_hour'), latency: 1, at: now - 1.hour - 1.second, key: 'before-1h')
      result = service.call(actor, now: now)

      expect(window(result, '1h')['qualified_follow_reject_events']).to eq 2
      expect(window(result, '24h')['qualified_follow_reject_events']).to eq 4
    end
  end

  describe 'read-only and privacy' do
    let(:rejector) { Fabricate(:account, username: 'private_rejector', domain: 'secret.example', actor_type: 'Service') }

    before do
      reject_from(rejector, latency: 4, at: now - 5.minutes, key: 'private')
    end

    it 'does not write ledger, enforcement, or relationship rows' do
      before_counts = mutation_counts

      service.call(actor, now: now)

      expect(mutation_counts).to eq before_counts
    end

    it 'does not emit acct, usernames, responder ids, domain names, or message bodies' do
      rejector_subject = ModerationSubject.find_by!(account_id: rejector.id)
      result = service.call(actor, now: now)
      rendered = scalar_values(result).map(&:to_s)

      expect(rendered).to_not include(
        rejector.acct,
        rejector.username,
        rejector.id.to_s,
        rejector_subject.id.to_s,
        'secret.example',
        'private_rejector'
      )
      expect(rendered).to_not include('content', 'text', 'note', 'comment', 'payload', 'ip')
    end
  end
end
# rubocop:enable Metrics/BlockLength
