# frozen_string_literal: true

class ActivityPub::FetchGroupAffiliationsService < BaseService
  include JsonLdHelper

  # Cached rows are positive evidence of relationships a remote Group published.
  # Absence and staleness are unknown and must not be interpreted as denial.
  MAX_ITEMS = 500
  MAX_PAGES = 20
  COLLECTION_TYPES = %w(
    Collection
    CollectionPage
    OrderedCollection
    OrderedCollectionPage
  ).freeze

  def call(account, collection: nil)
    return unless eligible?(account, collection)

    @account = account
    @failed = false
    records = collect_records(collection.presence || account.affiliations_url)
    replace_affiliations!(records) unless records.nil?
  end

  private

  def eligible?(account, collection)
    return false if account.local? || !account.group? || account.suspended?

    account.affiliations_url.present? || collection.is_a?(Hash)
  end

  def collect_records(collection_or_uri)
    @pages = 0
    @records = []
    @seen = {}

    collection = resolve_document(collection_or_uri)
    return if @failed

    while collection.is_a?(Hash)
      return if page_limit_reached?

      if redirect_to_first_page?(collection)
        collection = resolve_document(collection['first'])
        return if @failed || !collection.is_a?(Hash)

        next
      end

      items = items_from(collection)
      return if items.nil?
      return unless append_records(items)

      break if collection['next'].blank?

      collection = resolve_document(collection['next'])
      return if @failed || !collection.is_a?(Hash)
    end

    @records
  end

  def page_limit_reached?
    @pages += 1
    return false unless @pages > MAX_PAGES

    skip_snapshot!('page limit')
    true
  end

  def redirect_to_first_page?(collection)
    collection['first'].present? && !page_document?(collection)
  end

  def page_document?(collection)
    equals_or_includes?(collection['type'], 'CollectionPage') ||
      equals_or_includes?(collection['type'], 'OrderedCollectionPage')
  end

  def items_from(collection)
    values = ordered_collection?(collection) ? ordered_values(collection) : unordered_values(collection)
    return if values == :unsupported

    as_array(values || [])
  end

  def ordered_collection?(collection)
    equals_or_includes_any?(collection['type'], %w(OrderedCollection OrderedCollectionPage))
  end

  def unordered_values(collection)
    unless equals_or_includes_any?(collection['type'], %w(Collection CollectionPage))
      skip_snapshot!('unsupported collection type')
      return :unsupported
    end

    collection['items'].presence || collection['orderedItems'].presence
  end

  def ordered_values(collection)
    collection['orderedItems'].presence || collection['items'].presence
  end

  def append_records(items)
    limited = false

    items.each do |item|
      record = parse_relationship(item)
      next if record.nil?

      key = [record[:subject_uri], record[:relationship]]
      next if @seen[key]

      if @records.size >= MAX_ITEMS
        limited = true
        break
      end

      @seen[key] = true
      @records << record
    end

    return true unless limited

    skip_snapshot!('item limit')
    false
  end

  def resolve_document(collection_or_uri)
    return collection_or_uri if collection_or_uri.is_a?(Hash)

    uri = collection_uri(collection_or_uri)
    return skip_snapshot!('collection uri') if uri.blank? || non_matching_uri_hosts?(@account.uri, uri)

    json = fetch_resource_without_id_validation(uri, local_follower, true)
    return skip_snapshot!('collection document') unless json.is_a?(Hash) && supported_context?(json)

    json
  rescue Mastodon::UnexpectedResponseError, HTTP::Error, OpenSSL::SSL::SSLError, Mastodon::LengthValidationError, Oj::ParseError
    skip_snapshot!('collection fetch')
  end

  def collection_uri(value)
    uri = value_or_id(value)
    return unless uri.is_a?(String)

    stripped = uri.strip
    return if stripped.blank? || unsupported_uri_scheme?(stripped)

    stripped
  end

  def parse_relationship(item)
    return unless item.is_a?(Hash)
    return unless equals_or_includes?(item['type'], 'Relationship')
    return unless belongs_to_group?(item)

    subject_uri = normalized_string(value_or_id(item['subject']))
    relationship = normalized_relationship(item['relationship'])
    return if subject_uri.blank? || relationship.blank?
    return if subject_uri.length > GroupAffiliation::SUBJECT_URI_MAX_LENGTH
    return if relationship.length > GroupAffiliation::RELATIONSHIP_MAX_LENGTH

    {
      subject_uri: subject_uri,
      relationship: relationship,
      affiliation_uri: affiliation_uri_for(item),
    }
  end

  def normalized_relationship(value)
    raw = value.is_a?(Hash) ? value_or_id(value) : value
    normalized_string(raw)
  end

  def normalized_string(value)
    return unless value.is_a?(String)

    value.strip
  end

  def belongs_to_group?(item)
    [item['object'], item['attributedTo']].all? do |value|
      uri = normalized_string(value_or_id(value))
      uri.blank? || uri == @account.uri
    end
  end

  def affiliation_uri_for(item)
    uri = normalized_string(value_or_id(item['id']))
    return if uri.blank? || uri.length > GroupAffiliation::AFFILIATION_URI_MAX_LENGTH

    uri
  end

  def replace_affiliations!(records)
    now = Time.now.utc

    GroupAffiliation.transaction do
      @account.group_affiliations.delete_all
      insert_affiliations!(records, now) if records.any?
      @account.update_columns(affiliations_fetched_at: now)
    end
  ensure
    @account.association(:group_affiliations).reset
  end

  def insert_affiliations!(records, now)
    GroupAffiliation.insert_all!(records.map { |record| record.merge(group_account_id: @account.id, created_at: now, updated_at: now) })
  end

  def local_follower
    return @local_follower if defined?(@local_follower)

    @local_follower = @account.followers.local.without_suspended.first
  end

  def skip_snapshot!(reason)
    @failed = true
    Rails.logger.info("Group affiliation sync for account #{@account.id} kept the existing cache (#{reason})")
    nil
  end
end
