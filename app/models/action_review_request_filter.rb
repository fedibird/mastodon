# frozen_string_literal: true

class ActionReviewRequestFilter
  KEYS = %i(
    state
  ).freeze

  STATES = %w(pending approved rejected cancelled all).freeze

  attr_reader :params

  def initialize(params)
    @params = params
  end

  def results
    scope = ActionReviewRequest.all
    state = normalized_state
    scope = scope.public_send("#{state}_state") unless state == 'all'

    if state == 'pending'
      scope.order(requested_at: :asc, id: :asc)
    else
      scope.order(requested_at: :desc, id: :desc)
    end
  end

  def normalized_state
    value = params[:state].presence || 'pending'
    return value if STATES.include?(value)

    raise "Unknown filter: state=#{value}"
  end
end
