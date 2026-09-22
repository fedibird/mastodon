# frozen_string_literal: true

# Backfill for operational Follow Import batches that never received a v1
# shadow observation. Enqueue can be lost at preflight, and batches imported
# before this worker existed need the same causal snapshot. Historical cohort
# rows are ignored. This pass does not change preflight_state or execution.
#
# Interval is 10 minutes so it does not stack on the 5 minute follow-import
# schedulers. The import window matches the classifier lookback.
class Scheduler::FollowImportReviewSignalShadowScheduler
  include Sidekiq::Worker

  sidekiq_options retry: 0

  BATCH_LIMIT = 500
  WINDOW = 7.days

  def perform
    candidates.limit(BATCH_LIMIT).pluck(:id).each do |batch_id|
      FollowImport::ReviewSignalShadowWorker.perform_async(batch_id)
    end
  end

  private

  def candidates
    FollowImportBatch
      .operational_cohort
      .where('imported_at >= ?', WINDOW.ago)
      .where('(metadata ->> :key) IS NULL', key: FollowImportBatch::REVIEW_SIGNAL_SHADOW_V1_KEY)
      .order(:imported_at, :id)
  end
end
