# frozen_string_literal: true

module InviteCreationHelper
  def invite_creation_review(invite)
    return if invite.nil?

    reviews = instance_variable_get(:@invite_reviews)
    return if reviews.nil?

    reviews[invite.id]
  end
end
