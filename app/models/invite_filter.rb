# frozen_string_literal: true

class InviteFilter
  KEYS = %i(
    available
    expired
    review_pending
    review_rejected
  ).freeze

  attr_reader :params

  def initialize(params)
    @params = params
  end

  def results
    scope = Invite.order(created_at: :desc)

    params.each do |key, value|
      scope.merge!(scope_for(key, value)) if value.present?
    end

    scope
  end

  private

  def scope_for(key, _value)
    case key.to_s
    when 'available'
      Invite.available
    when 'expired'
      Invite.expired
    when 'review_pending'
      reviewed_invites(:pending)
    when 'review_rejected'
      reviewed_invites(:rejected)
    else
      raise "Unknown filter: #{key}"
    end
  end

  def reviewed_invites(state)
    ids = ActionReviewRequest.where(
      operation_type: 'invite_creation',
      resource_type: 'Invite',
      state: state
    ).select(:resource_id)
    Invite.where(id: ids)
  end
end
