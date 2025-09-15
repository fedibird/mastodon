# frozen_string_literal: true

class REST::StatusSerializer < ActiveModel::Serializer
  include Redisable

  attributes :id, :created_at, :updated_at, :in_reply_to_id, :in_reply_to_account_id,
             :sensitive, :spoiler_text, :visibility, :language,
             :uri, :url, :replies_count, :reblogs_count,
             :favourites_count, :emoji_reactions, :emoji_reactions_count,
             :status_reference_ids,
             :status_references_count, :status_referred_by_count,
             :searchability

  attribute :favourited, if: :current_user?
  attribute :reblogged, if: :current_user?
  attribute :muted, if: :current_user?
  attribute :bookmarked, if: :current_user?
  attribute :emoji_reactioned, if: :current_user?
  attribute :pinned, if: :pinnable?
  has_many :filtered, serializer: REST::FilterResultSerializer, if: :current_user?
  attribute :circle_id, if: :limited_owned_parent_status?

  attribute :content, unless: :source_requested?
  attribute :text, if: :source_requested?

  attribute :nyaize_content, if: :joke_applied?

  attribute :quote_id, if: :quote?

  attribute :expires_at, if: :expires?
  attribute :expires_action, if: :expires?
  attribute :visibility_ex, if: :visibility_ex?

  attribute :account
  attribute :reblog

  attribute :processing

  belongs_to :application, if: :show_application?

  has_many :ordered_media_attachments, key: :media_attachments, serializer: REST::MediaAttachmentSerializer
  has_many :ordered_mentions, key: :mentions
  has_many :tags
  has_many :emojis, serializer: REST::CustomEmojiSerializer

  has_one :preview_card, key: :card, serializer: REST::PreviewCardSerializer
  has_one :preloadable_poll, key: :poll, serializer: REST::PollSerializer

  delegate :quote?, to: :object

  attribute :needs_fetch, if: :needs_fetch?

  def application
    object.account.local? ? object.application : object.generator
  end

  def preview_card
    object.preview_card unless hide_preview_card?
  end

  def hide_preview_card?
    case object&.preview_card&.type
    when 'link'
      current_user&.setting_hide_link_preview
    when 'photo'
      current_user&.setting_hide_photo_preview
    when 'video'
      current_user&.setting_hide_video_preview
    end
  end

  def id
    object.id.to_s
  end

  def updated_at
    object.status_stat_updated_at || object.updated_at
  end

  def processing
    redis.exists?("statuses/#{object.id}/processing")
  end

  def in_reply_to_id
    object.in_reply_to_id&.to_s
  end

  def in_reply_to_account_id
    object.in_reply_to_account_id&.to_s
  end

  def quote_id
    object.quote_id.to_s
  end

  def account
    if instance_options[:compact]
      object.account.id.to_s
    else
      REST::AccountSerializer.new(object.account, root: false, scope: current_user, scope_name: :current_user)
    end
  end

  def reblog
    if object.reblog.nil?
      nil
    elsif instance_options[:compact]
      object.reblog.id.to_s
    else
      REST::StatusSerializer.new(object.reblog, root: false, relationships: instance_options[:relationships], account_relationships: instance_options[:account_relationships], application_name: instance_options[:application_name], compact: false, scope: current_user, scope_name: :current_user)
    end
  end

  def current_user?
    !current_user.nil?
  end

  def owned_status?
    current_user? && current_user.account_id == object.account_id
  end

  def show_application?
    !object.account.local? || object.account.user_shows_application? || owned_status?
  end

  def expires?
    object.expires? || object.expired?
  end

  def expires_at
    object&.status_expire&.expires_at || object.expired_at
  end

  def expires_action
    object&.status_expire&.action || 'mark'
  end

  def visibility_ex?
    !object.standard_visibility?
  end

  def visibility
    # This visibility is masked behind "private"
    # to avoid API changes because there are no
    # UX differences
    if object.limited_visibility?
      'private'
    elsif object.personal_visibility?
      'direct'
    else
      object.visibility
    end
  end

  def visibility_ex
    object.visibility
  end

  def searchability
    object.compute_searchability
  end

  def sensitive
    if current_user? && current_user.account_id == object.account_id
      object.sensitive
    else
      object.account.sensitized? || object.sensitive
    end
  end

  def limited_owned_parent_status?
    object.limited_visibility? && owned_status? && (!object.reply? || object.thread&.conversation_id != object.conversation_id)
  end

  def circle_id
    redis.get("statuses/#{object.id}/circle_id")
  end

  def uri
    ActivityPub::TagManager.instance.uri_for(object)
  end

  def content
    @content ||= Formatter.instance.format(object)
  end

  def nyaize_content
    @nyaize_content ||= Formatter.instance.format(object, nyaize: object.account.cat?)
  end

  def url
    ActivityPub::TagManager.instance.url_for(object)
  end

  def favourited
    if instance_options && instance_options[:relationships]
      instance_options[:relationships].favourites_map[object.id] || false
    else
      current_user.account.favourited?(object)
    end
  end

  def emoji_reactions
    object.grouped_emoji_reactions(current_user&.account)
  end

  def status_reference_ids
    object.references.map(&:id).map(&:to_s)
  end

  def reblogged
    if instance_options && instance_options[:relationships]
      instance_options[:relationships].reblogs_map[object.id] || false
    else
      current_user.account.reblogged?(object)
    end
  end

  def muted
    if instance_options && instance_options[:relationships]
      instance_options[:relationships].mutes_map[object.conversation_id] || false
    else
      current_user.account.muting_conversation?(object.conversation)
    end
  end

  def bookmarked
    if instance_options && instance_options[:relationships]
      instance_options[:relationships].bookmarks_map[object.id] || false
    else
      current_user.account.bookmarked?(object)
    end
  end

  def emoji_reactioned
    if instance_options && instance_options[:relationships]
      instance_options[:relationships].emoji_reactions_map[object.id] || false
    else
      current_user.account.emoji_reactioned?(object)
    end
  end

  def pinned
    if instance_options && instance_options[:relationships]
      instance_options[:relationships].pins_map[object.id] || false
    else
      current_user.account.pinned?(object)
    end
  end

  def filtered
    if instance_options && instance_options[:relationships]
      instance_options[:relationships].filters_map[object.id] || []
    else
      current_user.account.status_matches_filters(object)
    end
  end

  def pinnable?
    owned_status? &&
      !object.reblog? &&
      %w(public unlisted private).include?(object.visibility)
  end

  def source_requested?
    instance_options[:source_requested]
  end

  def joke_applied?
    !source_requested? && object.account.cat? && nyaize_content != content
  end

  def needs_fetch?
    object.needs_fetch?
  end

  def needs_fetch
    object.needs_fetch?
  end

  def ordered_mentions
    object.active_mentions.to_a.sort_by(&:id)
  end

  class ApplicationSerializer < ActiveModel::Serializer
    attributes :name, :website
  end

  class GeneratorSerializer < ActiveModel::Serializer
    attributes :name, :website
  end

  class MentionSerializer < ActiveModel::Serializer
    attributes :id, :username, :url, :acct, :group, :moved_acct

    def id
      object.account_id.to_s
    end

    def username
      object.account_username
    end

    def url
      ActivityPub::TagManager.instance.url_for(object.account)
    end

    def acct
      object.account.pretty_acct
    end

    def moved_acct
      object.account.moved_to_account&.pretty_acct || acct
    end

    def group
      object.account.group?
    end
  end

  class TagSerializer < ActiveModel::Serializer
    include RoutingHelper

    attributes :name, :url

    def url
      tag_url(object)
    end
  end
end

class REST::NestedQuoteSerializer < REST::StatusSerializer
  attribute :quote do
    nil
  end
  attribute :quote_muted, if: :current_user?

  def quote_muted
    if instance_options && instance_options[:account_relationships]
      instance_options[:account_relationships].muting[object.account_id] ? true : false || instance_options[:account_relationships].blocking[object.account_id] || instance_options[:account_relationships].blocked_by[object.account_id] || instance_options[:account_relationships].domain_blocking[object.account_id] || false
    else
      current_user.account.muting?(object.account) || object.account.blocking?(current_user.account) || current_user.account.blocking?(object.account) || current_user.account.domain_blocking?(object.account.domain)
    end
  end
end

class REST::StatusSerializer < ActiveModel::Serializer
  attribute :quote, unless: :official_quote?

  def quote
    if object.quote.nil?
      nil
    elsif instance_options[:compact]
      object.quote.id.to_s
    else
      REST::NestedQuoteSerializer.new(object.quote, root: false, relationships: instance_options[:relationships], account_relationships: instance_options[:account_relationships], application_name: instance_options[:application_name], compact: false, scope: current_user, scope_name: :current_user)
    end
  end

  def official_quote?
    [
      'Mastodon for iOS',
      'Mastodon for Android',
      'IceCubesApp',
    ].include? instance_options[:application_name]
  end

end
