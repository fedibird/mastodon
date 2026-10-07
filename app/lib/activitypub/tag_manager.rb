# frozen_string_literal: true

require 'singleton'

class ActivityPub::TagManager
  include Singleton
  include JsonLdHelper
  include RoutingHelper

  CONTEXT = 'https://www.w3.org/ns/activitystreams'

  COLLECTIONS = {
    public: 'https://www.w3.org/ns/activitystreams#Public',
  }.freeze

  def public_collection?(uri)
    uri == COLLECTIONS[:public] || uri == 'as:Public' || uri == 'Public'
  end

  def url_for(target)
    return unsupported_uri_scheme?(target.url) ? nil : target.url if target.respond_to?(:local?) && !target.local?

    return unless target.respond_to?(:object_type)

    case target.object_type
    when :person
      target.instance_actor? ? about_more_url(instance_actor: true) : short_account_url(target)
    when :note, :comment, :activity
      if target.reblog?
        activity_account_status_url(target.account, target)
      else
        short_account_status_url(target.account, target)
      end
    end
  end

  def uri_for(target)
    return target.uri if target.respond_to?(:local?) && !target.local?

    case target.object_type
    when :person
      target.instance_actor? ? instance_actor_url : account_url(target)
    when :note, :comment, :activity
      if target.reblog?
        activity_account_status_url(target.account, target)
      else
        account_status_url(target.account, target)
      end
    when :emoji
      emoji_url(target.shortcode.downcase)
    when :emoji_reaction
      emoji_reaction_url(target)
    when :conversation
      context_url(target)
    end
  end

  def key_uri_for(target)
    [uri_for(target), '#main-key'].join
  end

  def uri_for_username(username)
    account_url(username: username)
  end

  def generate_uri_for(_target)
    URI.join(root_url, 'payloads', SecureRandom.uuid)
  end

  def activity_uri_for(target)
    raise ArgumentError, 'target must be a local activity' unless %i(note comment activity).include?(target.object_type) && target.local?

    activity_account_status_url(target.account, target)
  end

  def replies_uri_for(target, page_params = nil)
    raise ArgumentError, 'target must be a local activity' unless %i(note comment activity).include?(target.object_type) && target.local?

    account_status_replies_url(target.account, target, page_params)
  end

  def references_uri_for(target, page_params = nil)
    raise ArgumentError, 'target must be a local activity' unless %i(note comment activity).include?(target.object_type) && target.local?

    account_status_references_url(target.account, target, page_params)
  end

  def emoji_reactions_uri_for(target, page_params = nil)
    raise ArgumentError, 'target must be a local activity' unless %i(note comment activity).include?(target.object_type) && target.local?

    account_status_emoji_reactions_url(target.account, target, page_params)
  end

  def followers_uri_for(target)
    target.local? ? account_followers_url(target) : target.followers_url.presence
  end

  # Primary audience of a status
  # Public statuses go out to primarily the public collection
  # Unlisted and private statuses go out primarily to the followers collection
  # Others go out only to the people they mention
  def to(status)
    addresses = case status.visibility
                when 'public'
                  [COLLECTIONS[:public]]
                when 'unlisted', 'private'
                  [account_followers_url(status.account)]
                when 'limited'
                  status.conversation_id.present? ? [uri_for(status.conversation)] : []
                when 'direct'
                  mentions_uris(status)
                else
                  []
                end

    append_audience_account(addresses, status)
  end

  # FEP-1b12 addresses the Group actor itself. Do not guess its followers collection.
  def append_audience_account(addresses, status)
    account = status.audience_account if status.respond_to?(:audience_account)
    return addresses if account.nil?

    uri = uri_for(account)
    return addresses if uri.blank?

    (addresses + [uri]).uniq
  end

  # Secondary audience of a status
  # Public statuses go out to followers as well
  # Unlisted statuses go to the public as well
  # Both of those and private statuses also go to the people mentioned in them
  # Direct ones don't have a secondary audience
  def cc(status)
    cc = []

    cc << uri_for(Status.include_expired.with_discarded.find(status.reblog_of_id).account) if status.reblog?

    case status.visibility
    when 'public'
      cc << account_followers_url(status.account)
    when 'unlisted'
      cc << COLLECTIONS[:public]
    end

    cc.concat(mentions_uris(status)) if Status::FOLLOWER_VISIBILITY.include?(status.visibility)

    cc
  end

  def searchable_by(status)
    searchable_by =
      case status.compute_searchability
      when 'public'
        [COLLECTIONS[:public]]
      when 'unlisted', 'private'
        [account_followers_url(status.account)]
      when 'limited'
        status.conversation_id.present? ? [uri_for(status.conversation)] : []
      else
        [uri_for(status.account)]
      end

    searchable_by.concat(mentions_uris(status))
  end

  def account_searchable_by(account)
    case account.searchability
    when 'public'
      [COLLECTIONS[:public]]
    when 'unlisted', 'private'
      [account_followers_url(account)]
    else
      [uri_for(account)]
    end
  end

  def mentions_uris(status)
    if status.account.silenced?
      # Only notify followers if the account is locally silenced
      account_ids = status.active_mentions.pluck(:account_id)
      uris = status.account.followers.where(id: account_ids).each_with_object([]) do |account, result|
        result << uri_for(account)
        result << followers_uri_for(account) if account.group?
      end.compact
      uris.concat(FollowRequest.where(target_account_id: status.account_id, account_id: account_ids).each_with_object([]) do |request, result|
        result << uri_for(request.account)
        result << followers_uri_for(request.account) if request.account.group?
      end.compact)
    else
      status.active_mentions.each_with_object([]) do |mention, result|
        result << uri_for(mention.account)
        result << followers_uri_for(mention.account) if mention.account.group?
      end.compact
    end
  end

  def local_uri?(uri)
    return false if uri.nil?

    uri  = Addressable::URI.parse(uri)
    host = uri.normalized_host
    host = "#{host}:#{uri.port}" if uri.port

    !host.nil? && (::TagManager.instance.local_domain?(host) || ::TagManager.instance.web_domain?(host))
  rescue Addressable::URI::InvalidURIError
    return false
  end

  def uri_to_local_id(uri, param = :id)
    path_params = Rails.application.routes.recognize_path(uri) rescue {}
    path_params[:username] = Rails.configuration.x.local_domain if path_params[:controller] == 'instance_actors'
    path_params[param]
  end

  def uri_to_resource(uri, klass)
    return if uri.nil?

    if local_uri?(uri)
      case klass.name
      when 'Account'
        klass.find_local(uri_to_local_id(uri, :username))
      else
        StatusFinder.new(uri).status
      end
    elsif OStatus::TagManager.instance.local_id?(uri)
      klass.find_by(id: OStatus::TagManager.instance.unique_tag_to_local_id(uri, klass.to_s))
    else
      klass.find_by(uri: uri.split('#').first)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
