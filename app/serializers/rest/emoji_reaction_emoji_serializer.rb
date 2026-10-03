# frozen_string_literal: true

class REST::EmojiReactionEmojiSerializer < ActiveModel::Serializer
  include RoutingHelper

  attributes :name, :domain, :custom, :count, :last_used_at

  attribute :url, if: :custom_emoji?
  attribute :static_url, if: :custom_emoji?
  attribute :width, if: :width?
  attribute :height, if: :height?
  attribute :thumbhash, if: :thumbhash?
  attribute :alternate_name, if: :alternate_name?
  attribute :ruby, if: :ruby?
  attribute :aliases, if: :aliases?

  def custom_emoji?
    object.custom && object.custom_emoji.present?
  end

  def url
    full_asset_url(object.custom_emoji.image.url)
  end

  def static_url
    full_asset_url(object.custom_emoji.image.url(:static), ext: '.png')
  end

  def width
    object.custom_emoji.width
  end

  def height
    object.custom_emoji.height
  end

  def thumbhash
    object.custom_emoji.thumbhash
  end

  def alternate_name
    object.custom_emoji.alternate_name
  end

  def ruby
    object.custom_emoji.ruby
  end

  def aliases
    [alternate_name, ruby].concat(object.custom_emoji.aliases).compact_blank.uniq
  end

  def width?
    custom_emoji? && !object.custom_emoji.width.nil?
  end

  def height?
    custom_emoji? && !object.custom_emoji.height.nil?
  end

  def thumbhash?
    custom_emoji? && object.custom_emoji.thumbhash.present?
  end

  def alternate_name?
    custom_emoji? && object.custom_emoji.alternate_name.present?
  end

  def ruby?
    custom_emoji? && object.custom_emoji.ruby.present?
  end

  def aliases?
    custom_emoji? && aliases.present?
  end
end
