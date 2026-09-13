# frozen_string_literal: true

# Single source of truth for follow-import execution timing knobs, so no timeout
# is hard-coded across workers/services.
#
# response_wait is how long a delivered target waits for an Accept/Reject before
# a (future) periodic sweeper transitions it to completed_no_response. The value
# here is PROVISIONAL / UNCALIBRATED — it should be tuned from real Accept/Reject
# latency; the "correct" number is deliberately not fixed as a spec here.
module FollowImport
  module ExecutionPolicy
    module_function

    RESPONSE_WAIT = 48.hours

    def response_wait
      RESPONSE_WAIT
    end

    def response_deadline_at(from = Time.now.utc)
      from + response_wait
    end
  end
end
