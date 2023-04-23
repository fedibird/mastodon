# frozen_string_literal: true

class ActivityPub::FetchOutboxService < BaseService
  include JsonLdHelper

  MAX_EXPIRATION = 2.minutes.freeze

  def call(account, **options)
    return if account.outbox_url.blank? || account.suspended? || account.local?
    return if account.outbox_next_page_url == '' && !options[:force]

    @account = account
    @options = options

    resource_url = @account.outbox_next_page_url.presence ||
      if (since = Follow.where(account: Account.local).where(target_account: @account).select('min(created_at) as since').take&.since) && (id = Status.where(account: @account).where(created_at: since..).where.not(id: StatusPin.where(account: @account)).reorder(id: :asc).take&.id)
        url = Addressable::URI.parse(@account.outbox_url)
        url.query_values = { max_id: id, until_id: id, page: true } if id.present?
        url.to_s
      else
        @account.outbox_url
      end

    collection = Rails.cache.fetch(to_key(resource_url), expires_in: MAX_EXPIRATION) { fetch_resource_without_id_validation(resource_url, local_follower) }

    if !supported_context?(collection)
      @account.account_stat.update!(outbox_next_page_url: '')
      return
    end

    items, next_page_url = collection_items(collection)
    @account.account_stat.update!(outbox_next_page_url: next_page_url)

    process_items(items)
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.debug "Error processing outbox ActivityPub object: #{e}"
    nil
  end

  private

  def collection_items(collection)
    limit         = @options[:limit].presence || 10
    all_items     = []
    next_page_url = collection['first']
    collection    = fetch_collection(next_page_url) if %w(Collection OrderedCollection).include?(collection['type']) && collection['first'].present?

    while collection.is_a?(Hash)
      items = begin
        case collection['type']
        when 'Collection', 'CollectionPage'
          as_array(collection['items'].presence || collection['orderedItems'].presence || [])
        when 'OrderedCollection', 'OrderedCollectionPage'
          as_array(collection['orderedItems'].presence || collection['items'].presence || [])
        end
      end

      if items.blank?
        next_page_url = ''
        break
      end

      exists_uris = Status
        .union_all(Status.where(uri: items.filter_map { |item| value_or_id(item['object']) if item['type'] == 'Create' }))
        .union_all(Status.where(account: @account, reblog_of_id: Status.where(uri: items.filter_map { |item| value_or_id(item['object']) if item['type'] == 'Announce' }).select(:id)))
        .pluck(:uri)
      items.filter! { |item| !exists_uris.include?(value_or_id(item['object'])) } if exists_uris.present?

      all_items.concat(items)

      if all_items.size > limit
        all_items = all_items.take(limit)
        break
      end

      next_page_url = collection['next'] || ""

      break if all_items.size == limit

      sleep(1)
      collection = next_page_url.present? ? (fetch_collection(next_page_url) rescue nil) : nil
    end

    [all_items, next_page_url]
  end

  def fetch_collection(collection_or_uri)
    return collection_or_uri if collection_or_uri.is_a?(Hash)
    return if non_matching_uri_hosts?(@account.uri, collection_or_uri)

    Rails.cache.fetch(to_key(collection_or_uri), expires_in: MAX_EXPIRATION) { fetch_resource_without_id_validation(collection_or_uri, local_follower, true) }
  end

  def process_items(items)
    Status.where(id: items.filter_map { |item| process_item(item)&.id })
  end

  def process_item(item)
    activity = ActivityPub::Activity.factory(item, @account, **@options.merge(delivery: false))
    activity&.perform
  end

  def local_follower
    return @local_follower if defined?(@local_follower)

    @local_follower = @account.followers.local.without_suspended.first
  end

  def to_key(url)
    "outbox:#{url}"
  end
end
