# frozen_string_literal: true

# Read-only decomposition of Follow Rejects received by one subject.
#
# Qualified rows are the same set NegativeSignalQualification already
# defines. This service only describes that set: how soon the rejection
# arrived, what the rejector's Account looks like right now, and whether
# the unique rejectors cluster by the domain retained on their
# ModerationSubject. None of those descriptions is a verdict, a weight,
# or an input to scoring, the follow gate, or Action Review.
#
# Actor type and Account#bot? are current attributes. They are not a
# snapshot from the moment of the rejection, and a missing Account is
# reported as unknown rather than guessed. Latency buckets are durations,
# not a human-versus-automated classification. Domain counts describe
# concentration of unique rejectors; they do not describe coordination,
# and domain names are never returned.
module Moderation
  class FollowRejectObservationService
    DEFAULT_WINDOWS = {
      '1h'  => 1.hour,
      '24h' => 24.hours,
      '7d'  => 7.days,
    }.freeze

    ACTOR_TYPE_KEYS = %w(Person Service Application Group Organization Other unknown).freeze
    KNOWN_ACTOR_TYPES = %w(Person Service Application Group Organization).freeze
    LATENCY_BUCKETS = %w(lte_5s gt_5s_lte_30s gt_30s_lte_5m gt_5m unknown).freeze

    # Internal grouping keys. They are not domains and never appear in output.
    LOCAL_DOMAIN = "\u0000local"
    UNKNOWN_DOMAIN = "\u0000unknown"

    NOTES = [
      'latency buckets are descriptive and do not classify a rejection as automated or human',
      'actor type and bot-like metadata are current Account attributes, not event-time historical snapshots',
      'Service/Application metadata does not prove automation or malicious behavior',
      'domain concentration does not prove coordination',
      'absence of observed negatives is not evidence of absence',
    ].freeze

    def call(subject_or_account, now: Time.now.utc, windows: DEFAULT_WINDOWS)
      subject = resolve_subject(subject_or_account)

      {
        'generated_at' => now.iso8601,
        'windows' => window_reports(subject, now, windows),
        'notes' => NOTES,
      }
    end

    private

    # Read-only resolution: never ModerationSubject.for_account!.
    def resolve_subject(subject_or_account)
      return subject_or_account if subject_or_account.is_a?(ModerationSubject)
      return if subject_or_account.nil?

      ModerationSubject.find_by(account_id: subject_or_account.id)
    end

    def window_reports(subject, now, windows)
      windows.each_with_object({}) do |(name, duration), reports|
        window_end = now
        window_start = now - duration
        events = follow_rejects(subject, window_start, window_end)
        reports[name.to_s] = summarize(events, window_start, window_end)
      end
    end

    def follow_rejects(subject, window_start, window_end)
      return [] if subject.nil?

      ModerationRejectionEvent
        .where(rejected_subject_id: subject.id, event_type: :follow_reject)
        .where(occurred_at: window_start..window_end)
        .includes(:preceding_interaction_event, rejector_subject: :account)
        .to_a
    end

    def summarize(events, window_start, window_end)
      qualified = events.select { |event| NegativeSignalQualification.qualified?(event) }
      latency = latency_buckets(qualified)
      responders = responder_index(qualified)

      {
        'window_start' => window_start.iso8601,
        'window_end' => window_end.iso8601,
        'raw_follow_reject_events' => events.size,
        'qualified_follow_reject_events' => qualified.size,
        'unqualified_follow_reject_events' => events.size - qualified.size,
        'qualified_unique_responders' => responders.size,
        'latency_buckets' => latency,
        'immediate_lte_5s_events' => latency['lte_5s'],
      }.merge(actor_fields(qualified, responders)).merge(domain_fields(responders))
    end

    def latency_buckets(events)
      counts = LATENCY_BUCKETS.index_with { 0 }

      events.each do |event|
        counts[latency_bucket(event.time_to_rejection)] += 1
      end

      counts
    end

    # Boundaries are inclusive on the slow side of each bucket:
    # 0..5s, (5s, 30s], (30s, 300s], and anything slower. A missing or
    # negative duration stays in unknown instead of being coerced.
    def latency_bucket(seconds)
      return 'unknown' unless seconds.is_a?(Numeric) && seconds.finite? && !seconds.negative?
      return 'lte_5s' if seconds <= 5
      return 'gt_5s_lte_30s' if seconds <= 30
      return 'gt_30s_lte_5m' if seconds <= 300

      'gt_5m'
    end

    def responder_index(events)
      index = {}

      events.each do |event|
        subject = event.rejector_subject
        next if subject.nil?

        entry = (index[subject.id] ||= responder_entry(subject))
        entry[:immediate_bot] = true if entry[:bot] && immediate?(event)
      end

      index
    end

    def responder_entry(subject)
      {
        actor_key: actor_type_key(subject),
        bot: bot_like?(subject),
        known: subject.account.present?,
        domain_bucket: domain_bucket(subject),
        immediate_bot: false,
      }
    end

    def actor_fields(events, responders)
      {
        'actor_types' => {
          'event_counts' => actor_event_counts(events),
          'unique_responder_counts' => actor_unique_counts(responders),
        },
        'bot_like_events' => events.count { |event| bot_like?(event.rejector_subject) },
        'bot_like_unique_responders' => responders.values.count { |entry| entry[:bot] },
        'immediate_lte_5s_bot_like_events' => events.count { |event| immediate_bot_event?(event) },
        'immediate_lte_5s_bot_like_unique_responders' => responders.values.count { |entry| entry[:immediate_bot] },
        'current_actor_metadata_known_unique_responders' => responders.values.count { |entry| entry[:known] },
        'current_actor_metadata_unknown_unique_responders' => responders.values.count { |entry| !entry[:known] },
      }
    end

    def actor_event_counts(events)
      counts = zero_actor_counts

      events.each do |event|
        counts[actor_type_key(event.rejector_subject)] += 1
      end

      counts
    end

    def actor_unique_counts(responders)
      counts = zero_actor_counts

      responders.each_value do |entry|
        counts[entry[:actor_key]] += 1
      end

      counts
    end

    def zero_actor_counts
      ACTOR_TYPE_KEYS.index_with { 0 }
    end

    # Blank actor_type follows Account#person_type? and is reported as Person.
    # Anything outside the known ActivityPub types is Other. No Account means
    # unknown: deletion, or a subject that was never attached.
    def actor_type_key(subject)
      account = subject&.account
      return 'unknown' if account.nil?

      actor_type = account.actor_type.to_s
      return 'Person' if actor_type.blank?
      return actor_type if KNOWN_ACTOR_TYPES.include?(actor_type)

      'Other'
    end

    # Account#bot? is true only for Application and Service. This is current
    # metadata, not a claim that the rejection was automated.
    def bot_like?(subject)
      account = subject&.account
      account.present? && account.bot?
    end

    def immediate?(event)
      latency_bucket(event.time_to_rejection) == 'lte_5s'
    end

    def immediate_bot_event?(event)
      immediate?(event) && bot_like?(event.rejector_subject)
    end

    # Concentration is over unique qualified rejectors.
    #
    # A local subject is one group, whatever its domain column says. A remote
    # subject contributes its retained domain, stripped and downcased, not the
    # live Account domain. A remote subject with no domain is counted in
    # unknown_domain_unique_responders and is left out of the domain groups,
    # so missing metadata is not treated as a shared domain. The share
    # denominator is still every qualified unique rejector.
    def domain_fields(responders)
      grouped = Hash.new(0)
      responders.each_value { |entry| grouped[entry[:domain_bucket]] += 1 }
      known_groups = grouped.reject { |bucket, _count| bucket == UNKNOWN_DOMAIN }
      largest = known_groups.values.max || 0

      {
        'unique_responder_domains' => known_groups.size,
        'largest_domain_responder_count' => largest,
        'largest_domain_responder_share' => share(largest, responders.size),
        'local_unique_responders' => grouped[LOCAL_DOMAIN],
        'unknown_domain_unique_responders' => grouped[UNKNOWN_DOMAIN],
      }
    end

    def domain_bucket(subject)
      return LOCAL_DOMAIN if subject.local_origin?

      domain = subject.domain.to_s.strip.downcase
      return UNKNOWN_DOMAIN if domain.empty?

      domain
    end

    def share(numerator, denominator)
      return 0.0 if denominator.zero?

      numerator.to_f / denominator
    end
  end
end
