# frozen_string_literal: true

class ActivityPub::Activity::Like < ActivityPub::Activity
  def perform
    @original_status = status_from_uri(object_uri)

    return if @original_status.nil? || delete_arrived_first?(@json['id'])
    return if @original_status.account.local? && (@original_status.account.blocking?(@account) || @account.blocking?(@original_status.account) || @original_status.account.domain_blocking?(@account.domain))

    with_redis_lock("like:#{object_uri}") do
      if shortcode.nil?
        process_favourite
      else
        process_reaction
      end
    end
  end

  private

  def process_favourite
    favourite = @original_status.favourites.find_by(account: @account)

    if favourite.nil?
      favourite = @original_status.favourites.create!(account: @account)
      Trends.statuses.register(@original_status)
      NotifyService.new.call(@original_status.account, :favourite, favourite) if @original_status.account.local?
    end

    # Record (idempotently) even when the favourite already exists, so that a
    # re-delivery repairs a ledger event a transient recorder failure missed.
    record_inbound_favourite(favourite) if @original_status.account.local?
  end

  def record_inbound_favourite(favourite)
    Moderation::EventRecorder.record_interaction(actor: @account, target: @original_status.account, event_type: :favourite, status: @original_status, source_record: favourite)
  end

  def process_reaction
    reaction = @original_status.emoji_reactions.find_by(account: @account, name: shortcode)
    stored_status = EmojiMutes::ReactionTarget.stored_status(@original_status)

    # An existing row is judged by the emoji it actually stored. Redelivery
    # must not repair notifications or the moderation ledger while that mute
    # still matches.
    return if reaction && EmojiMutes::ReactionPolicy.suppress_existing?(reaction)

    # Reject from the activity document before any emoji copy when that
    # identity is already enough. A tag that resolves to a different emoji
    # is checked again after resolution and before insert.
    if reaction.nil? && EmojiMutes::ReactionPolicy.reject_new?(stored_status, incoming_reaction_identity)
      return
    end

    emoji = resolve_incoming_custom_emoji
    return if emoji&.disabled?

    if reaction.nil?
      stored_identity = EmojiMutes::Identity.for_pair(shortcode, emoji)
      return if EmojiMutes::ReactionPolicy.reject_new?(stored_status, stored_identity)

      reaction = @original_status.emoji_reactions.create!(account: @account, name: shortcode, custom_emoji: emoji, uri: @json['id'])

      if @original_status.account.local? && !@account.silenced? && !@original_status.account.excluded_from_timeline_account_ids.include?(@account.id) && !@original_status.account.excluded_from_timeline_domains.include?(@account.domain)
        NotifyService.new.call(@original_status.account, :emoji_reaction, reaction)
        forward_for_emoji_reaction
        relay_for_emoji_reaction
      end
    end

    # Record (idempotently) even when the reaction already exists, so that a
    # re-delivery repairs a ledger event a transient recorder failure missed.
    if @original_status.account.local?
      Moderation::EventRecorder.record_interaction(actor: @account, target: @original_status.account, event_type: :reaction, status: @original_status, source_record: reaction)
    end
  rescue Seahorse::Client::NetworkingError
    nil
  end

  def resolve_incoming_custom_emoji
    uri = value_or_id(emoji_tag)
    return if uri.blank?

    image_url = emoji_tag.dig('icon', 'url')
    name      = emoji_tag['name']
    domain    = Addressable::URI.parse(uri).normalized_host
    domain    = nil if domain == Rails.configuration.x.local_domain

    if image_url.present? && name.present? && (domain.nil? || @account.domain == domain)
      CustomEmoji.find_or_create_by!(shortcode: shortcode, domain: domain) do |emoji|
        emoji.uri              = uri
        emoji.image_remote_url = image_url
      end
    else
      ResolveURLService.new.call(value_or_id(emoji_tag))
    end
  end

  # Identity from the activity document. This does not fetch or copy an emoji.
  def incoming_reaction_identity
    code = shortcode
    return nil if code.blank?

    tag = emoji_tag
    uri = value_or_id(tag) if tag.is_a?(Hash) || tag.is_a?(String)
    if uri.present?
      domain = Addressable::URI.parse(uri).normalized_host
      domain = nil if domain.blank? || domain == Rails.configuration.x.local_domain
      if domain.present?
        return { 'kind' => 'custom', 'scope' => 'remote', 'domain' => EmojiMutes::Identity.normalize_domain(domain), 'shortcode' => code }
      end

      local = CustomEmoji.local.find_by(shortcode: code)
      return { 'kind' => 'custom', 'scope' => 'local', 'custom_emoji_id' => local.id.to_s } if local
    end

    { 'kind' => 'unicode', 'native' => code }
  rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError, ArgumentError
    { 'kind' => 'unicode', 'native' => code }
  end

  def forward_for_emoji_reaction
    return unless @json['signature'].present?

    ActivityPub::RawDistributionWorker.perform_async(Oj.dump(@json), @original_status.account.id, [@account.preferred_inbox_url])
  end

  def relay_for_emoji_reaction
    return unless @json['signature'].present? && @original_status.public_visibility?

    ActivityPub::DeliveryWorker.push_bulk(Relay.enabled.pluck(:inbox_url)) do |inbox_url|
      [Oj.dump(@json), @original_status.account.id, inbox_url]
    end
  end

  def shortcode
    return @shortcode if defined?(@shortcode)

    @shortcode = begin
      if @json['_misskey_reaction'] == '⭐'
        nil
      else
        @json['content']&.delete(':')
      end
    end
  end

  def misskey_favourite?
    misskey_shortcode = @json['_misskey_reaction']&.delete(':')

    return misskey_shortcode == shortcode && misskey_shortcode == '⭐'
  end

  def emoji_tag
    return @emoji_tag if defined?(@emoji_tag)

    @emoji_tag = as_array(@json['tag']).find {|tag| tag.is_a?(String) || tag.is_a?(Hash) && tag['type'] == 'Emoji' }
  end
end
