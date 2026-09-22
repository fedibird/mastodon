# frozen_string_literal: true

# Persists the first shadow review-signal observation for one operational
# Follow Import batch. It does not change preflight, dispatch, or execution.
# A later run is a no-op. Transient evaluator failures are retried and are
# not written into metadata.
module FollowImport
  class ReviewSignalShadowWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'pull', retry: 5

    def perform(batch_id)
      batch = FollowImportBatch.find_by(id: batch_id)
      return if batch.nil?
      return unless batch.operational_dispatch_cohort?
      return if batch.review_signal_shadow_v1_recorded?

      batch.record_review_signal_shadow_v1!(FollowImport::ReviewSignalShadowEvaluator.new.call(batch))
    rescue StandardError => e
      Rails.logger.warn("[FollowImport::ReviewSignalShadowWorker] batch #{batch_id} #{FollowImport::ReviewSignalShadowEvaluator} #{e.class}")
      raise
    end
  end
end
