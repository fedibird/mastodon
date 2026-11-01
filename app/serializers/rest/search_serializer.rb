# frozen_string_literal: true

class REST::SearchSerializer < ActiveModel::Serializer
  def initialize(*)
    super
    return if instance_options[:account_tag_pages]
    return unless object.respond_to?(:statuses)

    instance_options[:account_tag_pages] = AccountTagPage::Pages.prefetch(object.statuses)
  end

  has_many :accounts, serializer: REST::AccountSerializer
  has_many :statuses, serializer: REST::StatusSerializer
  has_many :hashtags, serializer: REST::TagSerializer
  has_many :profiles, serializer: REST::AccountSerializer
  has_many :custom_emojis, serializer: REST::CustomEmojiDetailSerializer
end
