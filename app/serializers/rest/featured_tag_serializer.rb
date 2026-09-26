# frozen_string_literal: true

class REST::FeaturedTagSerializer < ActiveModel::Serializer
  include RoutingHelper

  attributes :id, :name, :url, :statuses_count, :last_status_at

  def id
    object.id.to_s
  end

  def url
    object.account.local? ? short_account_tag_url(object.account, object.tag) : object.url
  end

  def statuses_count
    object.statuses_count.to_s
  end

  def last_status_at
    object.last_status_at&.to_date&.iso8601
  end
end
