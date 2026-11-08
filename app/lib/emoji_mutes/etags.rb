# frozen_string_literal: true

class EmojiMutes::Etags
  def self.collection(account_id, revision)
    %(W/"emoji-mutes-#{account_id}-#{revision}")
  end

  def self.item(mute)
    %(W/"emoji-mute-#{mute.id}-#{mute.revision}")
  end

  def self.match?(header_value, etag)
    token = unwrap(header_value)
    expected = unwrap(etag)
    token.present? && token == expected
  end

  def self.unwrap(value)
    value.to_s.strip.delete_prefix('W/').delete('"')
  end
end
