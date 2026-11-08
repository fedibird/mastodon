# frozen_string_literal: true

class REST::EmojiReactionSerializer < ActiveModel::Serializer
  include RoutingHelper
  
  attributes :name

  attribute :url, if: :custom_emoji?
  attribute :static_url, if: :custom_emoji?
  attribute :domain, if: :custom_emoji?
  # Local identity is the database id. A remote cache id is not an identity,
  # so it is not sent. Two local rows can share a shortcode.
  attribute :custom_emoji_id, if: :local_custom_emoji?
  attribute :width, if: :width?
  attribute :height, if: :height?
  attribute :thumbhash, if: :thumbhash?
  attribute :alternate_name, if: :alternate_name?
  attribute :ruby, if: :ruby?

  belongs_to :account, serializer: REST::AccountSerializer

  def custom_emoji?
    object.custom_emoji.present?
  end

  def local_custom_emoji?
    custom_emoji? && object.custom_emoji.domain.blank?
  end

  def custom_emoji_id
    object.custom_emoji_id.to_s
  end

  def url
    full_asset_url(object.custom_emoji.image.url)
  end

  def static_url
    full_asset_url(object.custom_emoji.image.url(:static), ext: '.png')
  end

  def domain
    object.custom_emoji.domain
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

  def width?
    custom_emoji? && object.custom_emoji.width
  end

  def height?
    custom_emoji? && object.custom_emoji.height
  end

  def thumbhash?
    custom_emoji? && !object.custom_emoji.thumbhash.blank?
  end

  def alternate_name?
    custom_emoji? && object.custom_emoji.alternate_name.present?
  end

  def ruby?
    custom_emoji? && object.custom_emoji.ruby.present?
  end
end
