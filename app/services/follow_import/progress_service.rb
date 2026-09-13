# frozen_string_literal: true

# Read-only per-batch follow-import progress, aggregated straight from
# follow_import_targets (the source of truth). No counter cache yet — this keeps
# the numbers authoritative and simple; a cache can come later if needed.
#
# +completed+ is true only when a non-empty batch has every target in a terminal
# state. An empty batch (no targets) is reported as total 0 and completed false
# (there is nothing to complete).
module FollowImport
  class ProgressService
    STATE_NAMES = FollowImportTarget.states.keys.freeze

    def call(batch_or_id)
      batch_id = batch_or_id.respond_to?(:id) ? batch_or_id.id : batch_or_id
      by_state = counts_by_state(batch_id)

      total     = by_state.values.sum
      processed = FollowImportTarget::TERMINAL_STATES.sum { |state| by_state[state] }
      remaining = total - processed

      {
        'batch_id'              => batch_id,
        'total'                 => total,
        'pending'               => by_state['pending'],
        'queued'                => by_state['queued'],
        'awaiting_delivery'     => by_state['awaiting_delivery'],
        'awaiting_response'     => by_state['awaiting_response'],
        'accepted'              => by_state['accepted'],
        'rejected'              => by_state['rejected'],
        'completed_no_response' => by_state['completed_no_response'],
        'delivery_failed'       => by_state['delivery_failed'],
        'processed'             => processed,
        'remaining'             => remaining,
        'completed'             => total.positive? && remaining.zero?,
      }
    end

    # Coarse failure: could not be followed. Rejected is an explicit no;
    # delivery_failed never reached the recipient. completed_no_response is
    # neither — the wait ended without an accept or reject — so it stays
    # inside processed/waiting totals only.
    COARSE_FAILURE_STATES = %w(rejected delivery_failed).freeze

    # Coarse, user-facing progress for display. Deliberately omits internal state
    # names, gate/risk, and accept/reject detail — only how far along the import
    # is. `processed` counts every settled target (including failures); `failed`
    # is surfaced separately as the count that could not be followed.
    def user_summary(batch_or_id)
      progress = call(batch_or_id)

      {
        'total'      => progress['total'],
        'processed'  => progress['processed'],
        'waiting'    => progress['remaining'],
        'failed'     => COARSE_FAILURE_STATES.sum { |state| progress[state] },
        'completed'  => progress['completed'],
        'preparing'  => false,
      }
    end

    # Pre-batch phase: a follow Import exists (CSV retained through processor
    # retries and watchdog recovery) but no FollowImportBatch has been recorded.
    # Counts are unknown. Never treat absence of a batch as completed.
    def preparing_summary
      {
        'total'     => nil,
        'processed' => 0,
        'waiting'   => nil,
        'failed'    => 0,
        'completed' => false,
        'preparing' => true,
      }
    end

    private

    def counts_by_state(batch_id)
      raw          = FollowImportTarget.where(batch_id: batch_id).group(:state).count
      name_by_value = FollowImportTarget.states.invert
      by_state      = STATE_NAMES.index_with { 0 }

      raw.each do |key, value|
        name = key.is_a?(Integer) ? name_by_value[key] : key.to_s
        by_state[name] = value if name
      end

      by_state
    end
  end
end
