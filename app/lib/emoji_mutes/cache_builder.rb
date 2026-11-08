# frozen_string_literal: true

# Rebuilds the shared reaction cache. The top-level name group stays the
# public shape. `parts` is the identity breakdown and `v` marks the format.
# The payload is not viewer-specific.
class EmojiMutes::CacheBuilder
  include RoutingHelper

  GroupRecord = Struct.new(:name, :account_ids, :custom_emoji, :custom_emoji_id)

  def initialize(status)
    @status = status
  end

  def dump
    Oj.dump(groups)
  end

  def self.max_id(json)
    parsed = Oj.load(json.presence || '[]', mode: :strict)
    return if parsed.blank? || !parsed.is_a?(Array)

    parsed.filter_map { |group| group['max_id']&.to_i }.max
  rescue Oj::ParseError
    nil
  end

  def groups
    names = ordered_names
    return [] if names.empty?

    rows = @status.emoji_reactions.where(name: names).order(:created_at, :id).pluck(:id, :name, :custom_emoji_id, :account_id)
    emojis = CustomEmoji.where(id: rows.filter_map { |row| row[2] }.uniq).index_by(&:id)
    max_id = rows.map(&:first).max
    names.filter_map { |name| group_for(name, rows.select { |row| row[1] == name }, emojis, max_id) }
  end

  private

  def ordered_names
    @status.emoji_reactions.group(:name).order(Arel.sql('MIN(created_at) ASC')).limit(EmojiReactionValidator::LIMIT).pluck(:name)
  end

  def group_for(name, rows, emojis, max_id)
    parts = part_records(name, rows, emojis)
    return if parts.empty?

    representative = representative_for(parts)
    merged_ids = parts.flat_map(&:account_ids)
    payload = {
      'name' => name,
      'count' => merged_ids.size,
      'account_ids' => merged_ids,
      'v' => EmojiMutes::CACHE_VERSION,
      'max_id' => max_id.to_s,
      'parts' => parts.map { |part| part_payload(part) },
    }
    payload.merge!(display_fields(representative.custom_emoji))
    payload
  end

  def part_records(name, rows, emojis)
    grouped = {}
    rows.each do |_id, _name, emoji_id, account_id|
      grouped[emoji_id] ||= []
      grouped[emoji_id] << account_id.to_s
    end
    grouped.map do |emoji_id, account_ids|
      GroupRecord.new(name, account_ids, emojis[emoji_id], emoji_id)
    end
  end

  def representative_for(parts)
    custom = parts.select(&:custom_emoji)
    return parts.first if custom.empty?

    custom.min_by { |part| part.custom_emoji.id }
  end

  def part_payload(part)
    payload = {
      'custom_emoji_id' => part.custom_emoji_id&.to_s,
      'account_ids' => part.account_ids,
    }
    if part.custom_emoji
      payload['shortcode'] = part.custom_emoji.shortcode
      payload.merge!(display_fields(part.custom_emoji))
    elsif part.custom_emoji_id.nil?
      payload['native'] = part.name
    end
    payload
  end

  def display_fields(emoji)
    return {} if emoji.nil?

    fields = {
      'url' => full_asset_url(emoji.image.url),
      'static_url' => full_asset_url(emoji.image.url(:static)),
    }
    fields['domain'] = emoji.domain if emoji.domain.present?
    fields['width'] = emoji.width if emoji.width
    fields['height'] = emoji.height if emoji.height
    fields['alternate_name'] = emoji.alternate_name if emoji.alternate_name.present?
    fields['ruby'] = emoji.ruby if emoji.ruby.present?
    fields
  end
end
