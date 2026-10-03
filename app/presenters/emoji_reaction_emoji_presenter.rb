# frozen_string_literal: true

class EmojiReactionEmojiPresenter < ActiveModelSerializers::Model
  attr_reader :name, :custom_emoji

  def initialize(name:, custom_emoji_id:, count:, last_used_at:, custom_emoji:)
    super()

    @name = name
    @custom_emoji_id = custom_emoji_id
    @count = count
    @last_used_at = last_used_at
    @custom_emoji = custom_emoji
  end

  def count
    Integer(@count)
  end

  def last_used_at
    return Time.zone.parse(@last_used_at) if @last_used_at.is_a?(String)

    @last_used_at
  end

  def custom
    !@custom_emoji_id.nil?
  end

  def domain
    custom_emoji&.domain
  end
end
