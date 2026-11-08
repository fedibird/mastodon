# frozen_string_literal: true

class EmojiMutes::Document
  def self.collection(mutes, revision, availability)
    {
      revision: revision,
      emoji_mutes: mutes.map { |mute| item(mute, availability) },
    }
  end

  def self.item(mute, availability)
    payload = {
      id: mute.id.to_s,
      revision: mute.revision,
      emoji: reference(mute, availability),
      effects: effects(mute),
      replacement: mute.replacement,
      availability: availability.state_for(mute),
    }
    cache_id = availability.cache_id_for(mute)
    payload[:detail] = { cache_id: cache_id } if cache_id
    payload
  end

  def self.reference(mute, availability)
    case mute.kind
    when 'unicode'
      { kind: 'unicode', native: mute.native }
    when 'local'
      ref = { kind: 'custom', scope: 'local', custom_emoji_id: mute.custom_emoji_id.to_s }
      shortcode = availability.shortcode_for(mute)
      ref[:shortcode] = shortcode if shortcode.present?
      ref
    else
      { kind: 'custom', scope: 'remote', domain: mute.domain, shortcode: mute.shortcode }
    end
  end

  def self.effects(mute)
    EmojiMutes::EFFECTS.index_with { |name| mute.public_send(name) }
  end
end
