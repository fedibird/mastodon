# frozen_string_literal: true

# Read-only resolution. Mute and registration remain unavailable until
# those features exist; this object must not report them as allowed.
class EmojiReferences::Result
  attr_reader :reference, :detail

  def initialize(reference:, detail:, addable:, add_reason: nil)
    @reference = reference
    @detail = detail
    @addable = addable
    @add_reason = add_reason
  end

  def as_json
    {
      reference: reference,
      detail: detail,
      actions: {
        add_to_personal_category: add_action,
        mute: { allowed: false, reason: 'not_implemented' },
        request_registration: { allowed: false, reason: 'not_implemented' },
      },
    }
  end

  private

  def add_action
    return { allowed: true } if @addable

    { allowed: false, reason: @add_reason }
  end
end
