# frozen_string_literal: true

class ActivityPub::Activity::Like < ActivityPub::Activity
  def perform
    @original_status = status_from_uri(object_uri)

    return if @original_status.nil? || delete_arrived_first?(@json['id'])
    return if @original_status.account.local? && (@original_status.account.blocking?(@account) || @account.blocking?(@original_status.account) || @original_status.account.domain_blocking?(@account.domain))

    lock_or_fail("like:#{object_uri}") do
      if shortcode.nil?
        process_favourite
      else
        process_reaction
      end
    end
  end

  private

  def process_favourite
    return if @account.favourited?(@original_status)

    favourite = @original_status.favourites.create!(account: @account)

    NotifyService.new.call(@original_status.account, :favourite, favourite) if @original_status.account.local?
  end

  def process_reaction
    uri = value_or_id(emoji_tag)

    if uri.present?
      image_url = emoji_tag.dig('icon', 'url')
      name      = emoji_tag['name']
      domain    = Addressable::URI.parse(uri).normalized_host
      domain    = nil if domain == Rails.configuration.x.local_domain

      if image_url.present? && name.present? && (domain.nil? || @account.domain == domain)
        emoji = CustomEmoji.find_or_create_by!(shortcode: shortcode, domain: domain) do |emoji|
          emoji.uri              = uri
          emoji.image_remote_url = image_url
        end
      else
        emoji = ResolveURLService.new.call(value_or_id(emoji_tag))
      end

      return if emoji.disabled?
    end

    return if @account.reacted?(@original_status, shortcode, emoji)

    @original_status.emoji_reactions.create!(account: @account, name: shortcode, custom_emoji: emoji, uri: @json['id']).tap do |reaction|
      if @original_status.account.local? && !@account.silenced? && !@original_status.account.excluded_from_timeline_account_ids.include?(@account.id) && !@original_status.account.excluded_from_timeline_domains.include?(@account.domain)
        NotifyService.new.call(@original_status.account, :emoji_reaction, reaction)
        forward_for_emoji_reaction
        relay_for_emoji_reaction
      end
    end
  rescue Seahorse::Client::NetworkingError
    nil
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

    @emoji_tag = Array(@json['tag']).find {|tag| tag.is_a?(String) || tag['type'] == 'Emoji' }
  end
end
