# frozen_string_literal: true

# Rejects a new reaction from the local author of the status the row would be
# stored on. A boost author's mutes are not consulted. Remote authors are not
# guessed at. The check does not write and does not fetch.
class EmojiMutes::ReactionPolicy
  def self.rejected?(status, name:, custom_emoji: nil, remote_domain: nil, shortcode: nil)
    stored = stored_status(status)
    author = stored&.account
    return false unless author&.local?

    EmojiMutes::RuleSet.for(author.id).rejects?(
      name: name,
      custom_emoji: custom_emoji,
      remote_domain: remote_domain,
      shortcode: shortcode
    )
  end

  def self.stored_status(status)
    return if status.nil?

    status.reblog || status
  end
end
