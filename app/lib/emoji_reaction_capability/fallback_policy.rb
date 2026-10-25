# frozen_string_literal: true

module EmojiReactionCapability
  # Stored user choice for a Like sent to the server that hosts the post.
  # The effective value is allow, ask, or deny. Unset, blank, and anything
  # else read as allow and are not written back. P1c grandfathering is not
  # implemented; there is no source of "grandfathered".
  #
  # The safety form does not offer ask until the WebUI can show the
  # confirmation dialog (P2). A stored ask is still a real value for the
  # write gate. Saving ask from the form is refused while the dialog is absent,
  # so a person cannot turn the setting on and then have no way to answer.
  module FallbackPolicy
    VALUES = %w(allow ask deny).freeze
    FORM_CHOICES = %w(allow deny).freeze

    module_function

    def normalize(raw)
      return raw if VALUES.include?(raw)

      'allow'
    end

    # nil when the user record cannot be read. Callers must not treat that
    # as allow for a Like or an unknown delivery.
    def read(account)
      user = account.user
      return if user.nil?

      normalize(user.setting_emoji_reaction_fallback_policy)
    end

    # P2 replaces this with the reaction-picker dialog. Keep it a method so
    # the form and its spec can turn the choice on without a delivery change.
    def picker_confirmation_available?
      false
    end

    def form_choices
      picker_confirmation_available? ? VALUES : FORM_CHOICES
    end

    def form_selectable?(value)
      form_choices.include?(value)
    end
  end
end
