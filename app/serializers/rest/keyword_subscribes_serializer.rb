# frozen_string_literal: true

class REST::KeywordSubscribesSerializer < ActiveModel::Serializer
  attributes :id, :name, :keyword, :exclude_keyword, :ignorecase, :regexp, :ignore_block, :disabled, :match_hashtags, :match_urls

  def id
    object.id.to_s
  end
end
