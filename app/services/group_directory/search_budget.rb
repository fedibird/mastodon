# frozen_string_literal: true

# Bound for one directory HTTP request.
#
# Each Elasticsearch call has its own timeout. This stops the request when
# the calls add up: too many round trips, or too much wall time. The next
# search is not sent. The caller raises SearchUnavailable and does not
# return a partial page.
class GroupDirectory::SearchBudget
  MAX_CALLS = 25
  MAX_ELAPSED = 5.0

  def initialize(clock: nil)
    @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    @started = @clock.call
    @calls = 0
  end

  def track!
    @calls += 1
    return unless @calls > MAX_CALLS || elapsed > MAX_ELAPSED

    raise GroupDirectory::SearchUnavailable, 'search budget'
  end

  def elapsed
    @clock.call - @started
  end

  attr_reader :calls
end
