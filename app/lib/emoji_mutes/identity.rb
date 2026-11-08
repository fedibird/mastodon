# frozen_string_literal: true

# Pins a create-time reference. Local identity is the database id. Remote
# identity is the normalized domain plus shortcode. No remote fetch or copy.
class EmojiMutes::Identity
  attr_reader :kind, :native, :custom_emoji_id, :domain, :shortcode

  def self.for_create!(emoji)
    reference = EmojiReferences::Resolver.new.resolve(emoji).reference
    if reference[:kind] == 'unicode'
      new(kind: 'unicode', native: reference[:native])
    elsif reference[:scope] == 'remote'
      new(kind: 'remote', domain: reference[:domain], shortcode: reference[:shortcode])
    else
      new(kind: 'local', custom_emoji_id: reference[:custom_emoji_id].to_i, shortcode: reference[:shortcode])
    end
  end

  def initialize(**attrs)
    @kind = attrs[:kind]
    @native = attrs[:native]
    @custom_emoji_id = attrs[:custom_emoji_id]
    @domain = attrs[:domain]
    @shortcode = attrs[:shortcode]
  end

  def attributes
    {
      kind: kind,
      native: native,
      custom_emoji_id: custom_emoji_id,
      domain: domain,
      shortcode: shortcode,
    }
  end
end
