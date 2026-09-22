# frozen_string_literal: true

# Read-only factual context for an account-migration review.
#
# Counts and rates only. No score, recommendation, or identity inference.
# Returned-follow figures are temporal associations: an incoming follow
# happened after an observed outgoing follow or import, within the window.
# That does not show why the follow happened.
class AccountMigration::ReviewMetricsService
  WINDOWS = {
    '1h' => 1.hour,
    '24h' => 24.hours,
    '7d' => 7.days,
  }.freeze

  BEHAVIOR_FIELDS = %w(
    contacts_total
    unique_targets
    follows
    unique_follow_targets
    qualified_negative_events
    qualified_unique_negative_responders
    follow_rejects_received
    blocks_received
    reports_received
    qualified_negative_response_rate
    follow_reject_rate
    new_targets_after_first_negative_signal
    follows_after_first_negative_signal
  ).freeze

  RATE_FIELDS = %w(
    qualified_negative_response_rate
    follow_reject_rate
  ).freeze

  IMPORT_CONTEXT_FIELDS = %w(
    batch_count
    target_total
    resolved_target_total
    unresolved_target_total
    unresolved_target_ratio
    prior_relationship_known_targets
    latest_import_at
  ).freeze

  def call(account, as_of: Time.now.utc)
    as_of = as_of.utc
    behavior = Moderation::BehavioralMetricsService.new.call(account, now: as_of, windows: WINDOWS)
    subject = account.nil? ? nil : ModerationSubject.find_by(account_id: account.id)

    {
      'as_of' => as_of.iso8601,
      'generated_at' => as_of.iso8601,
      'account_age_seconds' => account_age_seconds(account, as_of),
      'followers_count' => counter(account, :followers_count),
      'following_count' => counter(account, :following_count),
      'statuses_count' => counter(account, :statuses_count),
      'follow_import_context' => import_context(behavior),
      'windows' => WINDOWS.keys.index_with { |key| window_payload(account, subject, behavior, key, as_of) },
    }
  end

  private

  def window_payload(account, subject, behavior, key, as_of)
    window_start = as_of - WINDOWS.fetch(key)
    behavior_window(behavior, key)
      .merge(returned_follow_counts(account, subject, window_start, as_of))
      .merge(follow_import_return_counts(account, subject, window_start, as_of))
  end

  def behavior_window(behavior, key)
    source = behavior.dig('windows', key) || {}
    BEHAVIOR_FIELDS.index_with do |field|
      RATE_FIELDS.include?(field) ? source[field].to_f : source[field].to_i
    end
  end

  def import_context(behavior)
    source = behavior['follow_import_context'] || {}
    IMPORT_CONTEXT_FIELDS.index_with do |field|
      if field == 'unresolved_target_ratio'
        source[field].to_f
      elsif field == 'latest_import_at'
        source[field]
      else
        source[field].to_i
      end
    end
  end

  def returned_follow_counts(account, subject, window_start, as_of)
    earliest = earliest_outgoing_follows(account, subject, window_start, as_of)
    returned = returned_counterpart_count(account&.id, earliest, as_of)
    {
      'returned_follows_after_outgoing' => returned,
      'returned_follow_rate' => ratio(returned, earliest.size),
    }
  end

  def follow_import_return_counts(account, subject, window_start, as_of)
    batches = import_batches(subject, window_start, as_of)
    earliest = earliest_import_targets(batches)
    returned = returned_counterpart_count(account&.id, earliest, as_of)
    {
      'follow_import_batches' => batches.nil? ? 0 : batches.count,
      'follow_import_unique_resolved_targets' => earliest.size,
      'follow_import_returned_follows' => returned,
      'follow_import_returned_follow_rate' => ratio(returned, earliest.size),
    }
  end

  # Ledger timestamps stay observable after the Follow row itself is gone.
  # Only subjects that still point at an Account can be matched to a return.
  def earliest_outgoing_follows(account, subject, window_start, as_of)
    return {} if account.nil? || subject.nil?

    ModerationInteractionEvent
      .where(actor_subject_id: subject.id, event_type: :follow, occurred_at: window_start..as_of)
      .where.not(target_subject_id: nil)
      .joins(:target_subject)
      .where.not(moderation_subjects: { account_id: nil })
      .group('moderation_subjects.account_id')
      .minimum(:occurred_at)
  end

  def import_batches(subject, window_start, as_of)
    return if subject.nil?

    FollowImportBatch.where(subject_id: subject.id, imported_at: window_start..as_of)
  end

  def earliest_import_targets(batches)
    return {} if batches.nil?

    FollowImportTarget
      .where(batch_id: batches.select(:id))
      .where.not(target_subject_id: nil)
      .joins(:target_subject, :batch)
      .where.not(moderation_subjects: { account_id: nil })
      .group('moderation_subjects.account_id')
      .minimum('follow_import_batches.imported_at')
  end

  def returned_counterpart_count(source_id, earliest_by_account, as_of)
    return 0 if source_id.nil? || earliest_by_account.empty?

    matched = Set.new
    Follow.where(target_account_id: source_id, account_id: earliest_by_account.keys).where('created_at <= ?', as_of).pluck(:account_id, :created_at).each do |account_id, created_at|
      outgoing_at = earliest_by_account[account_id]
      matched << account_id if outgoing_at && created_at && created_at >= outgoing_at
    end
    matched.size
  end

  def account_age_seconds(account, as_of)
    return if account.nil? || account.created_at.nil?

    (as_of - account.created_at).to_i
  end

  def counter(account, name)
    return 0 if account.nil?

    account.public_send(name).to_i
  end

  def ratio(numerator, denominator)
    return 0.0 if denominator.nil? || denominator.to_i.zero?

    numerator.to_f / denominator
  end
end
