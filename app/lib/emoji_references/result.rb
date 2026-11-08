# frozen_string_literal: true

# Read-only resolution. Registration stays unavailable. Mute storage exists,
# but replace_in_text and hide_in_picker are stored only until P3 applies them.
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
        mute: {
          allowed: true,
          applied: EmojiMute::APPLIED_EFFECTS,
          stored_only: EmojiMute::STORED_ONLY_EFFECTS,
        },
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
