# frozen_string_literal: true

class REST::AccountSerializer < ActiveModel::Serializer
  include RoutingHelper

  attributes :id, :username, :acct, :display_name, :locked, :bot, :cat, :discoverable, :group, :created_at,
             :note, :url, :avatar, :avatar_static, :header, :header_static, :searchability,
             :followers_count, :following_count, :subscribing_count, :statuses_count, :last_status_at,
             :avatar_thumbhash, :header_thumbhash, :other_settings

  has_one :moved_to_account, key: :moved, serializer: REST::AccountSerializer, if: :moved_and_not_nested?

  has_many :emojis, serializer: REST::CustomEmojiSerializer

  attribute :suspended,          if: :suspended?
  attribute :avatar_full,        if: :with_fullsize_avatar?
  attribute :avatar_full_static, if: :with_fullsize_avatar?
  attribute :header_full,        if: :with_fullsize_header?
  attribute :header_full_static, if: :with_fullsize_header?
  attribute :fetched,            if: :remote?
  attribute :followed_message,   if: :following?

  class FieldSerializer < ActiveModel::Serializer
    attributes :name, :value, :verified_at

    def value
      Formatter.instance.format_field(object.account, object.value)
    end
  end

  has_many :fields

  def id
    object.id.to_s
  end

  def acct
    object.pretty_acct
  end

  def note
    object.suspended? ? '' : Formatter.instance.simplified_format(object)
  end

  def followed_message
    object.suspended? ? '' : Formatter.instance.format_message(object, object.followed_message)
  end

  def url
    ActivityPub::TagManager.instance.url_for(object)
  end

  def avatar
    if respond_to?(:current_user) && current_user&.setting_use_low_resolution_thumbnails
      full_asset_url(object.suspended? ? object.avatar.default_url : object.avatar_tiny_url, ext: object.avatar_file_name)
    else
      full_asset_url(object.suspended? ? object.avatar.default_url : object.avatar_original_url)
    end
  end

  def avatar_static
    if respond_to?(:current_user) && current_user&.setting_use_low_resolution_thumbnails
      full_asset_url(object.suspended? ? object.avatar.default_url : object.avatar_tiny_static_url, ext: object.avatar_file_name)
    else
      full_asset_url(object.suspended? ? object.avatar.default_url : object.avatar_static_url, ext: object.avatar_file_name)
    end
  end

  def avatar_full
    full_asset_url(object.suspended? ? object.avatar.default_url : object.avatar_original_url)
  end

  def avatar_full_static
    full_asset_url(object.suspended? ? object.avatar.default_url : object.avatar_static_url)
  end

  def header
    if respond_to?(:current_user) && current_user&.setting_use_low_resolution_thumbnails
      full_asset_url(object.suspended? ? object.header.default_url : object.header_tiny_url, ext: object.header_file_name)
    else
      full_asset_url(object.suspended? ? object.header.default_url : object.header_original_url)
    end
  end

  def header_static
    if respond_to?(:current_user) && current_user&.setting_use_low_resolution_thumbnails
      full_asset_url(object.suspended? ? object.header.default_url : object.header_tiny_static_url, ext: object.header_file_name)
    else
      full_asset_url(object.suspended? ? object.header.default_url : object.header_static_url, ext: object.header_file_name)
    end
  end

  def header_full
    full_asset_url(object.suspended? ? object.header.default_url : object.header_original_url)
  end

  def header_full_static
    full_asset_url(object.suspended? ? object.header.default_url : object.header_static_url)
  end

  def created_at
    object.created_at.midnight.as_json
  end

  def last_status_at
    object.last_status_at&.to_date&.iso8601
  end

  def statuses_count
    respond_to?(:current_user) && current_user && current_user.account_id == object.id && current_user&.setting_hide_statuses_count_from_yourself ? 0 : object.public_statuses_count
  end

  def following_count
    respond_to?(:current_user) && current_user && current_user.account_id == object.id && current_user&.setting_hide_following_count_from_yourself ? 0 : object.public_following_count
  end

  def followers_count
    respond_to?(:current_user) && current_user && current_user.account_id == object.id && current_user&.setting_hide_followers_count_from_yourself ? 0 : object.public_followers_count
  end

  def subscribing_count
    respond_to?(:current_user) && current_user && current_user.account_id == object.id && current_user&.setting_hide_subscribing_count_from_yourself ? 0 : object.subscribing_count
  end

  def display_name
    object.suspended? ? '' : object.display_name
  end

  def locked
    object.suspended? ? false : object.locked
  end

  def bot
    object.suspended? ? false : object.bot
  end

  def cat
    object.suspended? ? false : object.cat
  end

  def discoverable
    object.suspended? ? false : object.discoverable
  end

  def moved_to_account
    object.suspended? ? nil : object.moved_to_account
  end

  def emojis
    object.suspended? ? [] : object.emojis
  end

  def fields
    object.suspended? ? [] : object.fields
  end

  def other_settings
    object.suspended? ? {} : object.other_settings.reject {|keys, value| Account::HIDDEN_OTHER_SETTING_KEYS.include? keys}
  end

  def suspended
    object.suspended?
  end

  delegate :suspended?, to: :object

  def remote?
    !object.local?
  end

  def fetched
    object.outbox_next_page_url == ''
  end

  def moved_and_not_nested?
    object.moved? && object.moved_to_account.moved_to_account_id.nil?
  end

  def with_fullsize_avatar?
    respond_to?(:current_user) && current_user&.setting_use_low_resolution_thumbnails && current_user&.setting_use_fullsize_avatar_on_detail
  end

  def with_fullsize_header?
    respond_to?(:current_user) && current_user&.setting_use_low_resolution_thumbnails && current_user&.setting_use_fullsize_header_on_detail
  end

  def following?
    respond_to?(:current_user) && (current_user&.account&.following?(object) || current_user&.account&.id == object.id) && object.followed_message.present?
  end
end
