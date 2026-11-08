# frozen_string_literal: true

# Read-only resolution. Registration stays unavailable. Mute can be stored;
# only reaction rejection and reaction hiding are enforced in this release.
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
          effects: {
            replace_in_text: 'stored',
            reject_reactions_to_own_posts: 'enforced',
            hide_reactions: 'enforced',
            hide_in_picker: 'stored',
          },
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
