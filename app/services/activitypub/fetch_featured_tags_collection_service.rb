# frozen_string_literal: true

class ActivityPub::FetchFeaturedTagsCollectionService < BaseService
  include JsonLdHelper

  def call(account, url)
    return if account.suspended? || account.local?

    @account = account

    if url.present?
      @json = fetch_resource(url, true, local_follower)

      return unless supported_context?(@json)

      process_items(collection_items(@json))
    else
      html  = fetch_public_html(account.url)
      items = collection_items_from_html(html) unless html.nil?
      process_items(items) unless items.nil?
    end

  end

  private

  def fetch_public_html(url)
    return @html if defined?(@html)

    Request.new(:get, url).add_headers('Accept' => 'text/html', 'User-Agent' => "#{Mastodon::Version.user_agent} Bot").perform do |res|
      if res.code == 200 && res.mime_type == 'text/html'
        @html = res.body_with_limit
      else
        @html = nil
      end
    end

    @html

  rescue Mastodon::LengthValidationError
    nil
  end

  def collection_items_from_html(html)
    Nokogiri::HTML.parse(html).css('.directory__tag a').filter_map do |a|
      name = /tagged\/(#{Tag::HASHTAG_NAME_RE})\z/.match(CGI.unescape(URI::parse(a['href']).path)).to_a[1]
      { 'type' => 'Hashtag', 'name' => "##{name}" } if name.present?
    end
  end

  def collection_items(collection)
    all_items = []

    collection = fetch_collection(collection['first']) if collection['first'].present?

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

      break if all_items.size >= FeaturedTag::LIMIT

      collection = collection['next'].present? ? fetch_collection(collection['next']) : nil
    end

    all_items
  end

  def fetch_collection(collection_or_uri)
    return collection_or_uri if collection_or_uri.is_a?(Hash)
    return if non_matching_uri_hosts?(@account.uri, collection_or_uri)

    fetch_resource_without_id_validation(collection_or_uri, local_follower, true)
  end

  def process_items(items)
    items        = items.filter { |item| item['type'] == 'Hashtag' && item['name'].present? }    
    item_by_name = items.index_by { |item| item['name'].delete_prefix('#') }
    to_remove    = []
    to_add       = item_by_name.keys

    FeaturedTag.where(account: @account).map(&:name).each do |name|
      if item_by_name.key?(name)
        to_add.delete(name)
      else
        to_remove << name
      end
    end

    FeaturedTag.includes(:tag).where(account: @account, tags: { name: to_remove }).delete_all unless to_remove.empty?

    to_add.each do |name|
      FeaturedTag.create!(account: @account, name: name, url: item_by_name[name]['href'])
    end
  end

  def local_follower
    return @local_follower if defined?(@local_follower)

    @local_follower = @account.followers.local.without_suspended.first
  end
end
