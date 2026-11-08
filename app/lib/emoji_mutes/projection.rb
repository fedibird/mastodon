# frozen_string_literal: true

# Projects the shared cache for one viewer. Viewer counts stay on the call
# result and on the existing per-call counter. They are not written into
# status_stats or onto a shared cache string.
class EmojiMutes::Projection
  DISPLAY_KEYS = %w(url static_url domain width height alternate_name ruby).freeze

  def self.apply(status, account)
    new(status, account).apply
  end

  def initialize(status, account)
    @status = status
    @account = account
  end

  def apply
    parsed = parse_cache
    if legacy?(parsed) && rules.hides_any?
      breakdown = EmojiMutes::Breakdown.for_status(@status, @account&.id)
      return project(breakdown) if breakdown.is_a?(Array)
    end
    return legacy_filter(parsed) if legacy?(parsed)

    project(parsed)
  end

  private

  def rules
    @rules ||= EmojiMutes::RuleSet.for(@account&.id)
  end

  def parse_cache
    parsed = Oj.load(@status.status_stat&.emoji_reactions_cache.presence || '[]', mode: :strict) || []
    parsed.is_a?(Array) ? parsed : []
  end

  def legacy?(parsed)
    parsed.any? { |group| !group.is_a?(Hash) || group['parts'].blank? || group['v'].to_i < EmojiMutes::CACHE_VERSION }
  end

  def project(groups)
    removal = removal_ids(groups)
    total = 0
    visible = groups.filter_map do |group|
      projected = project_group(group, removal)
      next if projected.nil?

      total += projected['count']
      projected
    end
    @status.instance_variable_set(:@emoji_reactions_count, total)
    visible
  end

  def project_group(group, removal)
    parts = visible_parts(group['parts'], removal)
    return if parts.empty?

    ids = parts.flat_map { |part| part['account_ids'] }
    payload = {
      'name' => group['name'],
      'count' => ids.size,
      'me' => @account.present? && ids.include?(@account.id.to_s),
      'account_ids' => ids,
      'parts' => parts,
    }
    copy_display(payload, representative(parts))
    payload
  end

  def visible_parts(parts, removal)
    Array(parts).filter_map do |part|
      next if rules.hides_part?(part)

      ids = Array(part['account_ids']).map(&:to_s) - removal
      next if ids.empty?

      part.merge('account_ids' => ids)
    end
  end

  def representative(parts)
    custom = parts.select { |part| part['custom_emoji_id'].present? }
    return parts.first if custom.empty?

    custom.min_by { |part| part['custom_emoji_id'].to_i }
  end

  def copy_display(payload, part)
    return if part.nil? || part['native'].present?

    DISPLAY_KEYS.each do |key|
      payload[key] = part[key] if part.key?(key)
    end
  end

  def removal_ids(groups)
    ids = groups.flat_map { |group| Array(group['parts']).flat_map { |part| part['account_ids'] } }
    hidden_account_ids(ids)
  end

  def hidden_account_ids(ids)
    if @account.present?
      domain_ids = domain_blocked_ids(ids)
      silenced = Account.excluded_silenced_account_ids - [@account.id]
      (@account.excluded_from_timeline_account_ids + domain_ids + silenced).uniq.map(&:to_s)
    else
      Account.excluded_silenced_account_ids.map(&:to_s)
    end
  end

  def domain_blocked_ids(ids)
    domains = @account.excluded_from_timeline_domains
    return [] if domains.blank? || ids.blank?

    Account.where(id: ids, domain: domains).pluck(:id)
  end

  def legacy_filter(emoji_reactions)
    total = 0
    visible = emoji_reactions.filter do |emoji_reaction|
      assign_legacy_accounts(emoji_reaction)
      total += emoji_reaction['count']
      emoji_reaction['count'].positive?
    end
    @status.instance_variable_set(:@emoji_reactions_count, total)
    visible
  end

  def assign_legacy_accounts(emoji_reaction)
    if @account.present?
      emoji_reaction['me'] = emoji_reaction['account_ids'].include?(@account.id.to_s)
      emoji_reaction['account_ids'] -= legacy_removed_ids(emoji_reaction['account_ids'])
    else
      emoji_reaction['me'] = false
      emoji_reaction['account_ids'] -= Account.excluded_silenced_account_ids.map(&:to_s)
    end
    emoji_reaction['count'] = emoji_reaction['account_ids'].size
  end

  def legacy_removed_ids(account_ids)
    (
      @account.excluded_from_timeline_account_ids +
      Account.where(id: account_ids, domain: @account.excluded_from_timeline_domains).pluck(:id) +
      (Account.excluded_silenced_account_ids - [@account.id])
    ).uniq.map(&:to_s)
  end
end
