# frozen_string_literal: true

module EmojiReactionCapability
  # The decision for one emoji kind (docs section 3.1, kinds.<kind>).
  # plan is what would be sent if the write proceeded (DeliveryPlan).
  KindDecision = Data.define(
    :kind,
    :mechanism,
    :availability,
    :can_add,
    :requires_confirmation,
    :reason,
    :effects,
    :limit,
    :plan
  )
end
