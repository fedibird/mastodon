# frozen_string_literal: true

# Fedibird emoji fields are merged from keys the tag actually carries.
# ProcessCustomEmojiService would clear category, license, and the rest when a
# Mastodon tag only includes name and icon, so it is not used here.
module ActivityPub::ProcessStatusUpdateEmoji
  private

  def update_emojis!
    return if skip_download?

    @raw_emojis.each { |tag| process_emoji_tag(tag) }
  end

  def process_emoji_tag(tag)
    parser = ActivityPub::Parser::CustomEmojiParser.new(tag)
    return if parser.shortcode.blank? || parser.image_remote_url.blank?

    emoji = CustomEmoji.find_or_initialize_by(shortcode: parser.shortcode, domain: @account.domain)
    emoji.uri = parser.uri if emoji.uri.blank? && parser.uri.present?
    assign_emoji_metadata(emoji, tag)
    emoji.image_remote_url = parser.image_remote_url
    emoji.updated_at = tag['updated'] if tag['updated']
    emoji.save
  rescue Seahorse::Client::NetworkingError => e
    Rails.logger.warn "Error storing emoji: #{e}"
  end

  def assign_emoji_metadata(emoji, tag)
    new_record = emoji.new_record?

    simple_emoji_fields.each do |key, writer|
      assign_emoji_field(tag, key, new_record) { |value| emoji.public_send(writer, value) }
    end

    assign_emoji_field(tag, 'copyPermission', new_record) { |value| emoji.copy_permission = copy_permission_from(value) }
    assign_emoji_field(tag, '_misskey_license', new_record) { |value| emoji.misskey_license = value_or_hash_value(value, 'freeText') }
    assign_emoji_field(tag, 'keywords', new_record) { |value| emoji.aliases = as_array(value).compact }
    assign_emoji_field(tag, 'relatedLink', new_record) { |value| emoji.related_links = as_array(value).compact }
    assign_emoji_field(tag, 'sensitive', new_record) { |value| emoji.sensitive = value ? true : false }
  end

  def simple_emoji_fields
    {
      'category' => :org_category=,
      'license' => :license=,
      'alternate_name' => :alternate_name=,
      'ruby' => :ruby=,
      'copyrightNotice' => :copyright_notice=,
      'creditText' => :credit_text=,
      'usageInfo' => :usage_info=,
      'creator' => :creator=,
      'description' => :description=,
      'isBasedOn' => :is_based_on=,
    }
  end

  def assign_emoji_field(tag, key, new_record)
    return unless new_record || tag.key?(key)

    yield tag[key]
  end

  def copy_permission_from(value)
    case value
    when 'allow', true, '1' then 'allow'
    when 'deny', false, '0' then 'deny'
    when 'conditional' then 'conditional'
    else 'none'
    end
  end
end
