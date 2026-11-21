# frozen_string_literal: true

# Bound for one directory HTTP request, from before the point in time
# opens until the page is about to be returned.
#
# track! counts an Elasticsearch call. check! applies the same deadline
# after follow lookup, after a database visibility check, and before the
# response is returned. A late database check does not turn into a 200.
class GroupDirectory::SearchBudget
  MAX_CALLS = 25
  MAX_ELAPSED = 5.0

  def initialize(clock: nil)
    @clock = clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    @started = @clock.call
    @calls = 0
  end

  def self.checkpoint!
    current&.check!
  end

  def self.current
    Thread.current[:group_directory_search_budget]
  end

  def self.current=(budget)
    Thread.current[:group_directory_search_budget] = budget
  end

  def track!
    @calls += 1
    check!
  end

  def check!
    return unless @calls > MAX_CALLS || elapsed > MAX_ELAPSED

    raise GroupDirectory::SearchUnavailable, 'search budget'
  end

  def elapsed
    @clock.call - @started
  end

  attr_reader :calls
end
