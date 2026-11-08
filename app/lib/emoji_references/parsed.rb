# frozen_string_literal: true

# Shape of a typed emoji reference after field checks and domain
# normalization. Database availability is a later step.
class EmojiReferences::Parsed
  def initialize(**attributes)
    @attributes = attributes
  end

  def kind
    @attributes.fetch(:kind)
  end

  def native
    @attributes[:native]
  end

  def scope
    @attributes[:scope]
  end

  def custom_emoji_id
    @attributes[:custom_emoji_id]
  end

  def shortcode
    @attributes[:shortcode]
  end

  def domain
    @attributes[:domain]
  end

  def unicode?
    kind == 'unicode'
  end

  def remote?
    scope == 'remote'
  end
end
