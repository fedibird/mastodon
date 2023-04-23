# frozen_string_literal: true

class ActivityPub::FetchReferencesService < BaseService
  include JsonLdHelper

  def call(status, collection_or_uri)
    @account = status.account

    collection_items(collection_or_uri)&.map { |item| value_or_id(item) }
  end

  private

  def collection_items(collection_or_uri)
    collection = fetch_collection(collection_or_uri)
    return unless collection.is_a?(Hash) && collection['first'].present?

    all_items = []
    collection = fetch_collection(collection['first'])

    while collection.is_a?(Hash)
      items = begin
        case collection['type']
        when 'Collection', 'CollectionPage'
          as_array(collection['items'].presence || collection['orderedItems'].presence || [])
        when 'OrderedCollection', 'OrderedCollectionPage'
          as_array(collection['orderedItems'].presence || collection['items'].presence || [])
        end
      end

      break if items.blank?

      all_items.concat(items)

      break if all_items.size >= StatusReferenceValidator::LIMIT

      collection = collection['next'].present? ? fetch_collection(collection['next']) : nil
    end

    all_items
  end

  def fetch_collection(collection_or_uri)
    return collection_or_uri if collection_or_uri.is_a?(Hash)
    return if non_matching_uri_hosts?(@account.uri, collection_or_uri)
    fetch_resource_without_id_validation(collection_or_uri, nil, true)
  end
end
