# frozen_string_literal: true

namespace :moderation do
  # Operator read-only diagnostics for one subject. Prints JSON and writes
  # nothing: no snapshots, no actions, no enforcement, no batch processing.
  #
  # Resolve by existing ModerationSubject id, or by Account id (looked up
  # without creating a subject — same as BehavioralMetricsService).
  #
  #   SUBJECT_ID=456 bundle exec rake moderation:diagnostics
  #   ACCOUNT_ID=123 bundle exec rake moderation:diagnostics
  #
  # Optional follow-attempt context is forwarded to the decision service only:
  #   MECHANISM=follow_import TARGET_LOCALITY=remote TARGET_LOCKED=false
  desc 'Print read-only moderation subject diagnostics as JSON (ACCOUNT_ID or SUBJECT_ID)'
  task diagnostics: :environment do
    account_id = ENV['ACCOUNT_ID'].presence
    subject_id = ENV['SUBJECT_ID'].presence

    if account_id.blank? && subject_id.blank?
      abort 'Provide ACCOUNT_ID or SUBJECT_ID (e.g. ACCOUNT_ID=123 bundle exec rake moderation:diagnostics)'
    end

    target =
      if subject_id
        subject = ModerationSubject.find_by(id: subject_id)
        abort "ModerationSubject #{subject_id} not found" if subject.nil?

        subject
      else
        account = Account.find_by(id: account_id)
        abort "Account #{account_id} not found" if account.nil?

        account
      end

    context = {}
    context['mechanism'] = ENV['MECHANISM'] if ENV['MECHANISM'].present?
    context['target_locality'] = ENV['TARGET_LOCALITY'] if ENV['TARGET_LOCALITY'].present?
    context['relationship_context'] = ENV['RELATIONSHIP_CONTEXT'] if ENV['RELATIONSHIP_CONTEXT'].present?
    context['target_locked'] = ENV['TARGET_LOCKED'] == 'true' if ENV['TARGET_LOCKED'].present?

    result = Moderation::SubjectDiagnosticsService.new.call(target, context: context)
    puts JSON.pretty_generate(result)
  end
end
