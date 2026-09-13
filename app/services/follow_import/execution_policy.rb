# frozen_string_literal: true

# Single source of truth for follow-import execution timing/pacing knobs, so no
# timeout or batch size is hard-coded across workers/services.
#
# response_wait is how long a delivered target waits for an Accept/Reject before
# the periodic sweeper transitions it to completed_no_response.
#
# execution_batch_size / execution_reschedule_in pace the DB-backed batch
# executor: it claims at most execution_batch_size pending targets per pass and
# reschedules the next pass after execution_reschedule_in — but only while it is
# still making forward progress (see BatchExecutionWorker).
#
# All values here are PROVISIONAL / UNCALIBRATED and env-overridable — they
# should be tuned from real operational behaviour; no "correct" number is fixed.
#
# gate_enforcement_enabled? is OFF by default: the follow gate is observed/logged
# during execution but must NOT affect it unless an operator explicitly opts in
# with the experimental flag. No real Follow Import friction ships enabled.
module FollowImport
  module ExecutionPolicy
    module_function

    RESPONSE_WAIT = 48.hours

    DEFAULT_BATCH_SIZE     = 50
    DEFAULT_RESCHEDULE_IN  = 30.seconds

    def response_wait
      RESPONSE_WAIT
    end

    def response_deadline_at(from = Time.now.utc)
      from + response_wait
    end

    def execution_batch_size
      size = ENV['FOLLOW_IMPORT_EXECUTION_BATCH_SIZE'].to_i
      size.positive? ? size : DEFAULT_BATCH_SIZE
    end

    def execution_reschedule_in
      seconds = ENV['FOLLOW_IMPORT_EXECUTION_INTERVAL'].to_i
      seconds.positive? ? seconds.seconds : DEFAULT_RESCHEDULE_IN
    end

    # Experimental. When false (default) the executor ignores the gate's proposal
    # entirely and executes at its normal pace; the gate is still evaluated and
    # logged for observation.
    def gate_enforcement_enabled?
      ENV['FOLLOW_IMPORT_GATE_ENFORCEMENT'].to_s == 'true'
    end
  end
end
