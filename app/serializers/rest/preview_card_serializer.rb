# frozen_string_literal: true

class REST::PreviewCardSerializer < ActiveModel::Serializer
  include RoutingHelper

  attributes :url, :title, :description, :language, :type,
             :author_name, :author_url, :provider_name,
             :provider_url, :html, :width, :height,
             :image, :image_description, :embed_url, :blurhash, :thumbhash, :published_at

  attribute :status_id, if: :status_id
  attribute :account_id, if: :account_id

  attr_reader :status, :account

  def initialize(object, options = {})
    super

    return if object.nil?

    @status  = EntityCache.instance.holding_status(object.url.delete_suffix('/references'))
    @account = @status&.account
    @account = EntityCache.instance.holding_account(object.url) if @status.nil?
  end

  def status_id
    status.id.to_s if status.present?
  end

  def account_id
    account.id.to_s if account.present?
  end

  def url
    object.redirected_url || object.url
  end

  def image
    if respond_to?(:current_user) && current_user&.setting_use_low_resolution_thumbnails
      object.image? ? full_asset_url(object.image.url(:tiny), ext: object.image_file_name) : nil
    else
      object.image? ? full_asset_url(object.image.url(:original)) : nil
    end
  end

  def html
    Sanitize.fragment(object.html, Sanitize::Config::MASTODON_OEMBED)
  end
end
