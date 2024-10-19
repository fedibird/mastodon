# frozen_string_literal: true

class ActivityPub::EmojiReactionSerializer < ActivityPub::Serializer
  context_extensions :emoji_react

  attributes :id, :type, :actor, :content
  attribute :virtual_object, key: :object

  has_many :virtual_tags, key: :tag, unless: -> { object.custom_emoji.nil? }

  def id
    ActivityPub::TagManager.instance.uri_for(object)
  end

  def type
    %w(Like EmojiReact).include?(instance_options[:type]) ? instance_options[:type] : 'Like'
  end

  def actor
    ActivityPub::TagManager.instance.uri_for(object.account)
  end

  def virtual_object
    ActivityPub::TagManager.instance.uri_for(object.status)
  end

  def content
    object.custom_emoji.nil? ? object.name : ":#{object.name}:"
  end

  def virtual_tags
    [object.custom_emoji]
  end

  class CustomEmojiSerializer < ActivityPub::EmojiSerializer
  end
end
