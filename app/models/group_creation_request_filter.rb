# frozen_string_literal: true

class GroupCreationRequestFilter
  KEYS = %i(
    state
  ).freeze

  STATES = %w(
    pending
    approved
    rejected
    cancelled
    all
  ).freeze

  attr_reader :params

  def initialize(params)
    @params = params
  end

  # Pending stays first inside "all". A single state filter is that state
  # only, newest request first. An unknown state falls back to the queue.
  def results
    scope = GroupCreationRequest.all
    scope = scope.where(state: normalized_state) unless normalized_state == 'all'
    pending = GroupCreationRequest.states.fetch(:pending)
    scope.order(Arel.sql("CASE WHEN group_creation_requests.state = #{pending} THEN 0 ELSE 1 END"))
         .order(requested_at: :desc, id: :desc)
  end

  def normalized_state
    value = params[:state].to_s
    value = 'pending' if value.blank?
    return value if STATES.include?(value)

    'pending'
  end
end
