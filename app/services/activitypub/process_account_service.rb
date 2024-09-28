# frozen_string_literal: true

class ActivityPub::ProcessAccountService < BaseService
  include JsonLdHelper
  include DomainControlHelper
  include Redisable

  # Should be called with confirmed valid JSON
  # and WebFinger-resolved username and domain
  def call(username, domain, json, options = {})
    return if json['inbox'].blank? || unsupported_uri_scheme?(json['id']) || domain_not_allowed?(domain)

    @options     = options
    @json        = json
    @uri         = @json['id']
    @username    = username
    @domain      = domain
    @shortcodes  = []
    @collections = {}

    RedisLock.acquire(lock_options) do |lock|
      if lock.acquired?
        @account            = Account.remote.find_by(uri: @uri) if @options[:only_key]
        @account          ||= Account.find_remote(@username, @domain)
        @old_public_key     = @account&.public_key
        @old_protocol       = @account&.protocol
        @old_searchability  = @account&.searchability
        @suspension_changed = false

        update_node if @account.nil? && !Node.domain(domain).exists?
        create_account if @account.nil?
        process_tags
        update_account
        process_attachments

        process_duplicate_accounts! if @options[:verified_webfinger]
      else
        raise Mastodon::RaceConditionError
      end
    end

    return if @account.nil?

    after_protocol_change! if protocol_changed?
    after_key_change! if key_changed? && !@options[:signed_with_known_key]
    clear_tombstones! if key_changed?
    after_suspension_change! if suspension_changed?
    # after_searchability_change! if searchability_changed?

    unless @options[:only_key] || @account.suspended?
      check_featured_collection! if @account.featured_collection_url.present?
      check_featured_tags_collection!
      check_links! unless @account.fields.empty?
    end

    @account
  rescue Oj::ParseError
    nil
  end

  private

  def update_node
    UpdateNodeService.new.call(@domain)
  end

  def create_account
    @account = Account.new
    @account.protocol          = :activitypub
    @account.username          = @username
    @account.domain            = @domain
    @account.private_key       = nil
    @account.suspended_at      = domain_block.created_at if auto_suspend?
    @account.suspension_origin = :local if auto_suspend?
    @account.silenced_at       = domain_block.created_at if auto_silence?
    @account.save
  end

  def update_account
    @account.last_webfingered_at = Time.now.utc unless @options[:only_key]
    @account.protocol            = :activitypub

    set_suspension!
    set_immediate_protocol_attributes!
    set_fetchable_key! unless @account.suspended? && @account.suspension_origin_local?
    set_immediate_attributes! unless @account.suspended?
    set_fetchable_attributes! unless @options[:only_key] || @account.suspended?

    @account.save_with_optional_media!
  end

  def set_immediate_protocol_attributes!
    @account.inbox_url               = @json['inbox'] || ''
    @account.outbox_url              = @json['outbox'] || ''
    @account.shared_inbox_url        = (@json['endpoints'].is_a?(Hash) ? @json['endpoints']['sharedInbox'] : @json['sharedInbox']) || ''
    @account.followers_url           = @json['followers'] || ''
    @account.url                     = url || @uri
    @account.uri                     = @uri
    @account.actor_type              = actor_type
    @account.created_at              = @json['published'] if @json['published'].present?
  end

  def set_immediate_attributes!
    @account.featured_collection_url      = @json['featured'] || ''
    @account.featured_tags_collection_url = @json['featuredTags'] || ''
    @account.devices_url                  = @json['devices'] || ''
    @account.display_name                 = fix_emoji(@json['name']) || ''
    @account.note                         = @json['summary'] || ''
    @account.locked                       = @json['manuallyApprovesFollowers'] || false
    @account.fields                       = property_values || {}
    @account.settings                     = defer_settings.merge(other_settings, birthday, address, is_cat, deny_subscribed, followed_message)
    @account.also_known_as                = as_array(@json['alsoKnownAs'] || []).map { |item| value_or_id(item) }
    @account.discoverable                 = @json['discoverable'] || false
    @account.indexable                    = @json['indexable'] || false
    @account.searchability                = searchability_from_audience
  end

  def set_fetchable_key!
    @account.public_key = public_key || ''
  end

  def set_fetchable_attributes!
    begin
      previous_avatar_remote_url = @account.avatar_remote_url
               avatar_remote_url = image_url('icon') || ''

      if avatar_remote_url.blank? || skip_download?
        @account.avatar = nil
      elsif @account.avatar_file_name.nil? || avatar_remote_url != previous_avatar_remote_url
        @account.avatar_remote_url = avatar_remote_url
      elsif @account.avatar_exists?
        @account.avatar.styles.keys.each do |style|
          @account.avatar.reprocess!(style) if style != @account.avatar.default_style && @account.needs_avatar_reprocess?(style)
        end
      end
    rescue Mastodon::UnexpectedResponseError, HTTP::TimeoutError, HTTP::ConnectionError, OpenSSL::SSL::SSLError
      RedownloadAvatarWorker.perform_in(rand(30..600).seconds, @account.id)
    end
    begin
      previous_header_remote_url = @account.header_remote_url
               header_remote_url = image_url('image') || ''

      if header_remote_url.blank? || skip_download?
        @account.header = nil
      elsif @account.header_file_name.nil? || header_remote_url != previous_header_remote_url
        @account.header_remote_url = header_remote_url
      elsif @account.header_exists?
        @account.header.styles.keys.each do |style|
          @account.header.reprocess!(style) if style != @account.header.default_style && @account.needs_header_reprocess?(style)
        end
      end
    rescue Mastodon::UnexpectedResponseError, HTTP::TimeoutError, HTTP::ConnectionError, OpenSSL::SSL::SSLError
      RedownloadHeaderWorker.perform_in(rand(30..600).seconds, @account.id)
    end
    @account.statuses_count    = outbox_total_items    if outbox_total_items.present?
    @account.following_count   = following_total_items if following_total_items.present?
    @account.followers_count   = followers_total_items if followers_total_items.present?
    @account.hide_collections  = following_private? || followers_private?
    @account.moved_to_account  = @json['movedTo'].present? ? moved_account : nil
  end

  def set_suspension!
    return if @account.suspended? && @account.suspension_origin_local?

    if @account.suspended? && !@json['suspended']
      @account.unsuspend!
      @suspension_changed = true
    elsif !@account.suspended? && @json['suspended']
      @account.suspend!(origin: :remote)
      @suspension_changed = true
    end
  end

  def after_protocol_change!
    ActivityPub::PostUpgradeWorker.perform_async(@account.domain)
  end

  def after_key_change!
    RefollowWorker.perform_async(@account.id)
  end

  def after_suspension_change!
    if @account.suspended?
      Admin::SuspensionWorker.perform_async(@account.id)
    else
      Admin::UnsuspensionWorker.perform_async(@account.id)
    end
  end

  def after_searchability_change!
    SearchabilityUpdateWorker.perform_async(@account.id) if @account.statuses.unset_searchability.exists?
  end

  def check_featured_collection!
    ActivityPub::SynchronizeFeaturedCollectionWorker.perform_async(@account.id, { 'hashtag' => @json['featuredTags'].blank? && !@account.featured_tags.exists? })
  end

  def check_featured_tags_collection!
    ActivityPub::SynchronizeFeaturedTagsCollectionWorker.perform_async(@account.id, @json['featuredTags'])
  end

  def check_links!
    VerifyAccountLinksWorker.perform_async(@account.id)
  end

  def process_duplicate_accounts!
    return unless Account.where(uri: @account.uri).where.not(id: @account.id).exists?

    AccountMergingWorker.perform_async(@account.id)
  end

  def actor_type
    if @json['type'].is_a?(Array)
      @json['type'].find { |type| ActivityPub::FetchRemoteAccountService::SUPPORTED_TYPES.include?(type) }
    else
      @json['type']
    end
  end

  def image_url(key)
    value = first_of_value(@json[key])

    return if value.nil?

    if value.is_a?(String)
      value = fetch_resource_without_id_validation(value)
      return if value.nil?
    end

    value = first_of_value(value['url']) if value.is_a?(Hash) && value['type'] == 'Image'
    value = value['href'] if value.is_a?(Hash)
    value if value.is_a?(String)
  end

  def public_key
    value = first_of_value(@json['publicKey'])

    return if value.nil?
    return value['publicKeyPem'] if value.is_a?(Hash)

    key = fetch_resource_without_id_validation(value)
    key['publicKeyPem'] if key
  end

  def url
    return if @json['url'].blank?

    url_candidate = url_to_href(@json['url'], 'text/html')

    if unsupported_uri_scheme?(url_candidate) || mismatching_origin?(url_candidate)
      nil
    else
      url_candidate
    end
  end

  def audience_searchable_by
    return nil if @json['searchableBy'].nil?

    as_array(@json['searchableBy']).map { |x| value_or_id(x) }
  end

  def searchability_from_audience
    if audience_searchable_by.nil?
      if @account.note.match? /#(<.+?>)?searchable_?by_?all(_?users?)?\b/i
        :public
      elsif @account.note.match? /#(<.+?>)?searchable_?by_?followers?(_?only)?\b/i
        :private
      elsif @account.note.match? /#(<.+?>)?searchable_?by_?reacted_?users?_?(_?only)?\b/i
        :direct
      elsif @json['indexable']
        :public
      elsif Node.domain(@domain).first&.upstream == "misskey"
        :public
      else
        :direct
      end
    elsif audience_searchable_by.any? { |uri| ActivityPub::TagManager.instance.public_collection?(uri) }
      :public
    elsif audience_searchable_by.include?(@account.followers_url)
      :private
    else
      :direct
    end
  end

  def subscribable_by
    return nil if @json['subscribableBy'].nil?

    @subscribable_by = as_array(@json['subscribableBy']).map { |x| value_or_id(x) }
  end

  def deny_subscribed
    return {} if @json['subscribableBy'].nil?
    { 'deny_subscribed' => subscribable_by&.all? { |uri| !ActivityPub::TagManager.instance.public_collection?(uri) } }
  end

  def property_values
    return unless @json['attachment'].is_a?(Array)
    as_array(@json['attachment']).select { |attachment| attachment['type'] == 'PropertyValue' }.map { |attachment| attachment.slice('name', 'value') }
  end

  def birthday
    return {} if @json['vcard:bday'].blank?
    { 'birthday' => ActiveRecord::Type::Date.new.cast(@json['vcard:bday']) }
  end

  def address
    return {} if @json['vcard:Address'].blank?
    { 'location' => @json['vcard:Address'] }
  end

  def is_cat
    return {} unless ActiveModel::Type::Boolean.new.cast(@json['isCat'])
    { 'is_cat' => true }
  end

  def followed_message
    return {} if @json['_misskey_followedMessage'].blank?
    { 'followed_message' => @json['_misskey_followedMessage'] }
  end

  DEFER_SETTINGS_KEYS = %w(
    birthday
    birth_year
    birth_month
    birth_day
    location
    followed_message
    cat_ears_color
    noindex
  ).freeze

  def defer_settings
    @account.settings.select { |key, _| DEFER_SETTINGS_KEYS.include?(key) }
  end

  def other_settings
    return {} unless @json['otherSetting'].is_a?(Array)
    @json['otherSetting'].each_with_object({}) { |v, h| h.merge!({v['name'] => v['value']}) if v['type'] == 'PropertyValue' }
  end

  def mismatching_origin?(url)
    needle   = Addressable::URI.parse(url).host
    haystack = Addressable::URI.parse(@uri).host

    !haystack.casecmp(needle).zero?
  end

  def outbox_total_items
    collection_info('outbox').first
  end

  def following_total_items
    collection_info('following').first
  end

  def followers_total_items
    collection_info('followers').first
  end

  def following_private?
    !collection_info('following').last
  end

  def followers_private?
    !collection_info('followers').last
  end

  def collection_info(type)
    return [nil, nil] if @json[type].blank?
    return @collections[type] if @collections.key?(type)

    collection = fetch_resource_without_id_validation(@json[type])

    total_items = collection.is_a?(Hash) && collection['totalItems'].present? && collection['totalItems'].is_a?(Numeric) ? collection['totalItems'] : nil
    has_first_page = collection.is_a?(Hash) && collection['first'].present?
    @collections[type] = [total_items, has_first_page]
  rescue HTTP::Error, OpenSSL::SSL::SSLError, Mastodon::LengthValidationError
    @collections[type] = [nil, nil]
  end

  def moved_account
    account   = ActivityPub::TagManager.instance.uri_to_resource(@json['movedTo'], Account)
    account ||= ActivityPub::FetchRemoteAccountService.new.call(@json['movedTo'], break_on_redirect: true)
    account
  end

  def skip_download?
    @account.suspended? || domain_block&.reject_media?
  end

  def auto_suspend?
    domain_block&.suspend?
  end

  def auto_silence?
    domain_block&.silence?
  end

  def domain_block
    return @domain_block if defined?(@domain_block)
    @domain_block = DomainBlock.rule_for(@domain)
  end

  def key_changed?
    !@old_public_key.nil? && @old_public_key != @account.public_key
  end

  def suspension_changed?
    @suspension_changed
  end

  def clear_tombstones!
    Tombstone.where(account_id: @account.id).delete_all
  end

  def protocol_changed?
    !@old_protocol.nil? && @old_protocol != @account.protocol
  end

  def searchability_changed?
    !@old_searchability.nil? && @old_searchability != @account.searchability
  end

  def lock_options
    { redis: redis, key: "process_account:#{@uri}", autorelease: 15.minutes.seconds }
  end

  def process_tags
    return if @json['tag'].blank?

    as_array(@json['tag']).each do |tag|
      process_emoji tag if equals_or_includes?(tag['type'], 'Emoji')
    end
  end

  def process_attachments
    return if @json['attachment'].blank?

    previous_proofs = @account.identity_proofs.to_a
    current_proofs  = []

    as_array(@json['attachment']).each do |attachment|
      next unless equals_or_includes?(attachment['type'], 'IdentityProof')
      current_proofs << process_identity_proof(attachment)
    end

    previous_proofs.each do |previous_proof|
      next if current_proofs.any? { |current_proof| current_proof.id == previous_proof.id }
      previous_proof.delete
    end
  end

  def process_emoji(tag)
    return if skip_download?
    return if tag['name'].blank? || tag['icon'].blank? || tag['icon']['url'].blank?

    shortcode       = tag['name'].delete(':')
    image_url       = tag['icon']['url']
    uri             = tag['id']

    emoji = CustomEmoji.find_or_initialize_by(shortcode: shortcode, domain: @account.domain) { |emoji| emoji.uri = uri }

    emoji.org_category     = tag['category']
    emoji.copy_permission  = case tag['copyPermission'] when 'allow', true, '1' then 'allow' when 'deny', false, '0' then 'deny' when 'conditional' then 'conditional' else 'none' end
    emoji.license          = tag['license']
    emoji.aliases          = as_array(tag['keywords'])
    emoji.usage_info       = tag['usageInfo']
    emoji.author           = tag['author']
    emoji.description      = tag['description']
    emoji.is_based_on      = tag['isBasedOn']
    emoji.sensitive        = tag['sensitive']
    emoji.image_remote_url = tag['icon']['url']
    emoji.updated_at       = tag['updated'] if tag['updated']
    emoji.save

    @shortcodes << shortcode unless emoji.nil?
  rescue Seahorse::Client::NetworkingError => e
    Rails.logger.warn "Error storing emoji: #{e}"
  end

  def process_identity_proof(attachment)
    provider          = attachment['signatureAlgorithm']
    provider_username = attachment['name']
    token             = attachment['signatureValue']

    @account.identity_proofs.where(provider: provider, provider_username: provider_username).find_or_create_by(provider: provider, provider_username: provider_username, token: token)
  end

  def fix_emoji(text)
    return text if text.blank? || @shortcodes.empty?

    fixed_text = text.dup

    @shortcodes.each do |shortcode|
      fixed_text.gsub!(/([^\s\u200B])(:#{shortcode}:)/, "\\1\u200B\\2")
      fixed_text.gsub!(/(:#{shortcode}:)([^\s\u200B])/, "\\1\u200B\\2")
    end

    fixed_text
  end
end
