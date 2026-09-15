# frozen_string_literal: true

# Observes account resolution for a Follow Import target. Records resolved vs
# unresolved_or_unavailable; does not guess Stoplight fallback vs not-found
# (both currently return nil). Recording failures never raise.
module FollowImport
  class ResolutionObserver
    def self.observe(target_id:, acct:, stoplight_wrapped:, sidekiq_queue:, sidekiq_job_id:)
      started_at = Time.now.utc
      error = nil
      account = nil

      begin
        account = yield
      rescue StandardError => e
        error = e
        raise
      ensure
        record(
          target_id: target_id,
          acct: acct,
          stoplight_wrapped: stoplight_wrapped,
          sidekiq_queue: sidekiq_queue,
          sidekiq_job_id: sidekiq_job_id,
          started_at: started_at,
          account: account,
          error: error
        )
      end

      account
    end

    def self.record(target_id:, acct:, stoplight_wrapped:, sidekiq_queue:, sidekiq_job_id:, started_at:, account:, error:)
      target = FollowImportTarget.find_by(id: target_id)

      FollowImport::Telemetry.record_transport(
        batch_id: target&.batch_id,
        target_id: target_id,
        phase: 'resolve_account',
        destination_domain: target&.destination_domain.presence || FollowImport::DestinationDomain.from_acct(acct),
        sidekiq_queue: sidekiq_queue,
        sidekiq_job_id: sidekiq_job_id,
        started_at: started_at,
        finished_at: Time.now.utc,
        outcome: resolve_outcome(account, error),
        error_class: error&.class&.name,
        metadata: {
          'schema' => FollowImport::Telemetry::SCHEMA_NAME,
          'schema_version' => FollowImport::Telemetry::SCHEMA_VERSION,
          'stoplight_wrapped' => stoplight_wrapped,
        }
      )
    rescue StandardError => e
      FollowImport::Telemetry.warn_failure('transport', e)
      nil
    end
    private_class_method :record

    def self.resolve_outcome(account, error)
      return 'unknown_exception' if error
      return 'resolved' if account.present?

      # Stoplight fallback and a genuine not-found both yield nil with the
      # current RelationshipWorker API. Do not guess which one it was.
      'unresolved_or_unavailable'
    end
    private_class_method :resolve_outcome
  end
end
