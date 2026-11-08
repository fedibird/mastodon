# frozen_string_literal: true

# One query for the legacy caches on a page. Statuses past the cap are marked
# skipped and are not mute-filtered, because a partial read would drop the
# wrong identity. The result is not written into status_stats.
class EmojiMutes::Breakdown
  def self.prepare(statuses, account_id, status_limit: EmojiMutes::LEGACY_STATUS_LIMIT, row_limit: EmojiMutes::LEGACY_ROW_LIMIT)
    rules = EmojiMutes::RuleSet.for(account_id)
    EmojiMutes::Current.breakdown_account_id = account_id
    EmojiMutes::Current.breakdowns = {}
    return unless rules.hides_any?

    legacy = Array(statuses).compact.uniq.select { |status| legacy?(status) }
    chosen = legacy.first(status_limit)
    (legacy - chosen).each { |status| EmojiMutes::Current.breakdowns[status.id] = :skipped }
    load(chosen.map(&:id), row_limit)
  end

  def self.for_status(status, account_id)
    return if status.nil?

    prepared = EmojiMutes::Current.breakdown_account_id == account_id
    cached = EmojiMutes::Current.breakdowns&.dig(status.id)
    return cached if prepared && (cached || !legacy?(status))
    return cached if cached

    load([status.id], EmojiMutes::LEGACY_ROW_LIMIT)
    EmojiMutes::Current.breakdowns[status.id]
  end

  def self.legacy?(status)
    cache = status.status_stat&.emoji_reactions_cache.to_s
    cache.present? && cache !~ /"v"\s*:\s*#{EmojiMutes::CACHE_VERSION}\b/
  end

  def self.load(status_ids, row_limit)
    EmojiMutes::Current.breakdowns ||= {}
    status_ids.each { |id| EmojiMutes::Current.breakdowns[id] = [] }
    return if status_ids.empty?

    rows = EmojiReaction.where(status_id: status_ids).order(:created_at, :id).limit(row_limit + 1).pluck(:status_id, :name, :custom_emoji_id, :account_id)
    if rows.size > row_limit
      status_ids.each { |id| EmojiMutes::Current.breakdowns[id] = :skipped }
      return
    end

    emojis = CustomEmoji.where(id: rows.filter_map { |row| row[2] }.uniq).index_by(&:id)
    rows.group_by(&:first).each do |status_id, status_rows|
      EmojiMutes::Current.breakdowns[status_id] = groups_for(status_rows, emojis)
    end
  end

  def self.groups_for(rows, emojis)
    names = []
    buckets = {}
    rows.each do |_status_id, name, emoji_id, account_id|
      names << name unless buckets.key?(name)
      buckets[name] ||= {}
      buckets[name][emoji_id] ||= []
      buckets[name][emoji_id] << account_id.to_s
    end
    names.first(EmojiReactionValidator::LIMIT).map do |name|
      {
        'name' => name,
        'parts' => buckets[name].map { |emoji_id, account_ids| part_for(name, emoji_id, emojis[emoji_id], account_ids) },
      }
    end
  end

  def self.part_for(name, emoji_id, emoji, account_ids)
    part = { 'custom_emoji_id' => emoji_id&.to_s, 'account_ids' => account_ids }
    if emoji
      part['shortcode'] = emoji.shortcode
      part['domain'] = emoji.domain if emoji.domain.present?
    elsif emoji_id.nil?
      part['native'] = name
    end
    part
  end
end
