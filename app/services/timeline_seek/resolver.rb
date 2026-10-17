# frozen_string_literal: true

# Resolves a seek target against one windowed-history source.
#
# DB timelines reuse PublicFeed / TagFeed / GroupFeed / PersonalFeed, so the
# point check and the date probe are id-ordered LIMIT queries (statuses pkey
# or the partial public/account indexes), not a created_at scan.
# Home, limited, and list feeds are Redis ZSETs trimmed to
# FeedManager::MAX_ITEMS. A missing member is outside the retained window,
# which is not proof the status was never in the feed.
class TimelineSeek::Resolver
  include Redisable

  DATE_PAGE = 20
  DATE_MAX_PAGES = 4
  ACCOUNT_PROBE_LIMIT = 20
  PREFERENCES = %w(nearest before after).freeze
  SEARCH_TEXT_KEYS = %w(q query text raw body).freeze

  def initialize(account, user: nil, application: nil)
    @account = account
    @user = user
    @application = application
  end

  def call(payload)
    payload ||= {}
    return TimelineSeek::Result.unsupported('search_text_not_accepted') if payload[:reject_search_text]

    source = payload[:source].to_s
    kind = payload[:kind].to_s
    entry = TimelineSeek::Capability.lookup(source, kind)
    return TimelineSeek::Result.unsupported(entry.reason, capability: entry.level) unless entry.level == 'supported' || entry.level == 'approximate'
    return TimelineSeek::Result.unsupported('version') unless payload[:version].to_i == TimelineSeek::Capability::VERSION
    return TimelineSeek::Result.unsupported('preference') unless PREFERENCES.include?(payload[:preference].to_s.presence || 'nearest')

    @source = source
    @kind = kind
    @entry = entry
    @context = (payload[:context] || {}).to_h.symbolize_keys
    @preference = payload[:preference].to_s.presence || 'nearest'
    @target = (payload[:seek_target] || payload[:target] || {}).to_h.symbolize_keys
    return TimelineSeek::Result.unsupported('search_text_not_accepted') if search_text_key?(@target)

    reader = build_reader
    return reader if reader.is_a?(TimelineSeek::Result)

    case kind
    when 'status', 'searchHit'
      resolve_status(reader, parse_id(@target[:id]), search_hit: kind == 'searchHit')
    when 'date'
      resolve_date(reader)
    when 'account'
      resolve_account(reader)
    else
      TimelineSeek::Result.unsupported('unknown_kind')
    end
  end

  # Shared with batch membership. Does not accept a seek target or search text.
  def open_reader(source, context)
    @source = source.to_s
    @context = (context || {}).to_h.symbolize_keys
    @entry = TimelineSeek::Capability.lookup(@source, 'membership')
    build_reader
  end

  private

  def search_text_key?(hash)
    hash.keys.map(&:to_s).intersect?(SEARCH_TEXT_KEYS)
  end

  def build_reader
    case @source
    when 'home', 'limited'
      return TimelineSeek::Result.unsupported('missing_account') if @account.nil?

      vis = visibility_list
      return vis if vis.is_a?(TimelineSeek::Result)

      feed = HomeFeed.new(@account)
      TimelineSeek::FeedReader.new(feed, visibilities: vis, redis_key: FeedManager.instance.key(:home, @account.id), redis: redis, regenerating: feed.regenerating?)
    when 'list'
      return TimelineSeek::Result.unsupported('missing_account') if @account.nil?

      list_id = context_id
      return TimelineSeek::Result.unsupported('missing_source') if list_id.nil?

      list = List.where(account: @account).find(list_id)
      TimelineSeek::FeedReader.new(ListFeed.new(list), redis_key: FeedManager.instance.key(:list, list.id), redis: redis)
    when 'hashtag'
      tag_reader
    when 'public'
      options = public_options
      TimelineSeek::FeedReader.new(PublicFeed.new(@account, options), unfiltered: TimelineSeek::FeedReader.new(PublicFeed.new(nil, options)))
    when 'domain'
      domain_reader
    when 'group'
      group_reader
    when 'personal'
      return TimelineSeek::Result.unsupported('missing_account') if @account.nil?

      TimelineSeek::FeedReader.new(PersonalFeed.new(@account, personal_options))
    else
      TimelineSeek::Result.unsupported('unknown_source')
    end
  end

  def tag_reader
    name = clean_tag(@context[:hashtag])
    return TimelineSeek::Result.unsupported('missing_source') if name.blank?

    tag = Tag.find_normalized(name)
    return TimelineSeek::FeedReader.new(nil, empty: true) if tag.nil?

    options = public_options.merge(any: tag_list(:any), all: tag_list(:all), none: tag_list(:none))
    TimelineSeek::FeedReader.new(TagFeed.new(tag, @account, options), unfiltered: TimelineSeek::FeedReader.new(TagFeed.new(tag, nil, options)))
  end

  def domain_reader
    raw = @context[:domain].to_s.strip
    return TimelineSeek::Result.unsupported('missing_source') if raw.blank?
    return TimelineSeek::Result.unavailable('domain_unavailable', capability: @entry.level) unless domain_available?(raw)

    options = public_options.merge(local: false, domain: raw)
    TimelineSeek::FeedReader.new(PublicFeed.new(@account, options), unfiltered: TimelineSeek::FeedReader.new(PublicFeed.new(nil, options)))
  end

  def group_reader
    group_id = context_id
    return TimelineSeek::Result.unsupported('missing_source') if group_id.nil?

    group = Account.groups.find(group_id)
    return TimelineSeek::Result.unsupported('remote_group') if group.domain.present?

    options = {
      only_media: flag(:only_media),
      without_media: flag(:without_media),
      without_bot: without_bot?,
      tagged: clean_tag(@context[:tagged]),
    }
    TimelineSeek::FeedReader.new(GroupFeed.new(group, @account, options), unfiltered: TimelineSeek::FeedReader.new(GroupFeed.new(group, nil, options)))
  end

  def resolve_status(reader, status_id, search_hit:)
    return TimelineSeek::Result.unsupported('invalid_id') if status_id.nil?

    extra = []
    extra << 'search_hit_is_membership_only' if search_hit
    extra << retention_limitation if reader.redis?
    extra << 'feed_regenerating' if reader.regenerating?

    if reader.redis?
      return resolve_redis_status(reader, status_id, extra)
    end

    # contains? is the feed scope, not viewer authorization. A group scope can
    # still return an id StatusPolicy#show? rejects.
    if reader.contains?(status_id)
      denied = concealed(status_id)
      return denied if denied

      return TimelineSeek::Result.resolved(status_id, capability: @entry.level, limitations: extra)
    end

    conceal_or(status_id) do
      if reader.unfiltered&.contains?(status_id)
        TimelineSeek::Result.not_visible(capability: @entry.level, limitations: extra, reason: 'viewer_filter')
      else
        TimelineSeek::Result.not_in_source(capability: @entry.level, limitations: extra)
      end
    end
  end

  def resolve_redis_status(reader, status_id, limitations)
    in_set = reader.in_retained_set?(status_id)
    # The ZSET is a retained window, not the current permission. A block,
    # delete, expiry, or visibility change can leave the id in the set.
    if in_set && reader.selectable?(status_id)
      denied = concealed(status_id)
      return denied if denied

      return TimelineSeek::Result.resolved(status_id, capability: 'approximate', limitations: limitations)
    end

    conceal_or(status_id) do
      if in_set
        TimelineSeek::Result.not_in_source(capability: 'approximate', limitations: limitations, reason: 'source_filter')
      else
        reason = reader.regenerating? ? 'feed_regenerating' : 'outside_retained_range'
        TimelineSeek::Result.unavailable(reason, capability: 'approximate', limitations: limitations)
      end
    end
  end

  def resolve_date(reader)
    parsed = parse_time(@target[:at])
    return parsed if parsed.is_a?(TimelineSeek::Result)

    time, day = parsed
    limitations = ['id_order_not_created_at']
    limitations << 'utc_day_start' if day
    limitations << retention_limitation if reader.redis?
    limitations << 'feed_regenerating' if reader.regenerating?

    probe = Mastodon::Snowflake.id_at(time, with_random: false)
    older, older_capped = collect_side(reader, :older, probe + 1, time)
    newer, newer_capped = collect_side(reader, :newer, probe, time)
    limitations << 'date_probe_budget' if older_capped || newer_capped
    chosen, precision = pick_status(older + newer, time)
    if precision && @preference != 'nearest' && !precision_matches_preference?(precision)
      limitations << 'preference_unmet'
    end

    if chosen
      return TimelineSeek::Result.resolved(chosen.id, capability: 'approximate', precision: precision, limitations: limitations)
    end

    if reader.redis?
      return TimelineSeek::Result.unavailable('feed_regenerating', capability: 'approximate', limitations: limitations) if reader.regenerating?
      return TimelineSeek::Result.not_found(capability: 'approximate', limitations: limitations) if reader.retained_count.zero? && reader.page(1).empty?

      TimelineSeek::Result.unavailable('outside_retained_range', capability: 'approximate', limitations: limitations)
    elsif reader.page(1).empty?
      TimelineSeek::Result.not_found(capability: 'approximate', limitations: limitations)
    else
      TimelineSeek::Result.unavailable('date_probe_exhausted', capability: 'approximate', limitations: limitations)
    end
  end

  def resolve_account(reader)
    account_id = parse_id(@target[:account_id])
    return TimelineSeek::Result.unsupported('invalid_id') if account_id.nil?

    target = Account.find_by(id: account_id)
    return TimelineSeek::Result.not_found(capability: 'approximate') if target.nil? || target.suspended?

    limitations = ['account_probe_limit']
    limitations << retention_limitation if reader.redis?
    # expired_at IS NULL keeps the probe on index_statuses_20210710
    # (account_id, id DESC) instead of walking every row for the account.
    probed = Status.where(account_id: target.id, expired_at: nil).reorder(id: :desc).limit(ACCOUNT_PROBE_LIMIT).to_a
    probed.each do |status|
      next unless StatusPolicy.new(@account, status).show?
      next unless account_status_in_source?(reader, status.id)

      return TimelineSeek::Result.resolved(status.id, capability: 'approximate', precision: 'newest-in-probe', limitations: limitations)
    end

    TimelineSeek::Result.unavailable('account_probe_exhausted', capability: 'approximate', limitations: limitations)
  end

  def account_status_in_source?(reader, status_id)
    if reader.redis?
      reader.in_retained_set?(status_id) && reader.selectable?(status_id)
    else
      reader.contains?(status_id)
    end
  end

  def collect_side(reader, direction, cursor, time)
    collected = []
    pages = 0
    capped = false

    while pages < DATE_MAX_PAGES && cursor
      rows = direction == :older ? reader.page(DATE_PAGE, max_id: cursor) : reader.page(DATE_PAGE, min_id: cursor)
      pages += 1
      break if rows.empty?

      collected.concat(rows)
      crossed = if direction == :older
                  collected.any? { |status| status.created_at <= time }
                else
                  collected.any? { |status| status.created_at > time }
                end
      break if crossed

      next_cursor = direction == :older ? rows.last.id : rows.first.id
      if next_cursor.nil? || next_cursor == cursor || rows.length < DATE_PAGE
        break
      end

      cursor = next_cursor
      capped = true if pages == DATE_MAX_PAGES
    end

    [collected, capped && pages == DATE_MAX_PAGES]
  end

  def pick_status(statuses, time)
    unique = statuses.uniq(&:id)
    before = unique.select { |status| status.created_at <= time }.max_by { |status| [status.created_at, status.id] }
    after = unique.select { |status| status.created_at > time }.min_by { |status| [status.created_at, status.id] }
    chosen = case @preference
             when 'before' then before || after
             when 'after' then after || before
             else nearest_status(before, after, time)
             end
    return [nil, nil] unless chosen

    precision = if (chosen.created_at - time).abs < 1
                  'exact'
                elsif chosen.created_at <= time
                  'nearest-before'
                else
                  'nearest-after'
                end
    [chosen, precision]
  end

  def nearest_status(before, after, time)
    return before unless after
    return after unless before

    before_distance = time - before.created_at
    after_distance = after.created_at - time
    after_distance < before_distance ? after : before
  end

  def precision_matches_preference?(precision)
    return true if precision == 'exact'

    (@preference == 'before' && precision == 'nearest-before') || (@preference == 'after' && precision == 'nearest-after')
  end

  # A status the viewer cannot open is not_found, including when it is
  # missing or still inside the source. not_in_source / not_visible would
  # confirm that a hidden row exists.
  def conceal_or(status_id)
    denied = concealed(status_id)
    return denied if denied

    yield
  end

  def concealed(status_id)
    record = Status.include_expired.includes(:account, :mentions).find_by(id: status_id)
    return nil if record && StatusPolicy.new(@account, record).show?

    TimelineSeek::Result.not_found(capability: @entry.level == 'supported' ? 'supported' : 'approximate')
  end

  def parse_time(value)
    text = value.to_s
    if text.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      date = Date.iso8601(text)
      return [Time.utc(date.year, date.month, date.day), true]
    end
    if text.match?(/\A\d{4}-\d{2}-\d{2}T/) && !text.match?(/(?:Z|[+-]\d{2}:?\d{2})\z/)
      return TimelineSeek::Result.unsupported('timezone_required')
    end

    [Time.iso8601(text).utc, false]
  rescue ArgumentError
    TimelineSeek::Result.unsupported('invalid_time')
  end

  def parse_id(value)
    TimelineSeek::StatusId.parse(value)
  end

  def context_id
    parse_id(@context[:id] || @context[:list_id] || @context[:group_id])
  end

  def visibility_list
    raw = @context[:visibilities]
    return [] if raw.blank?

    values = Array(raw).map(&:to_s)
    known = Status.visibilities.keys
    return TimelineSeek::Result.unsupported('invalid_visibility') if values.any? { |value| known.exclude?(value) }

    values
  end

  def public_options
    {
      remote: flag(:remote),
      only_media: flag(:only_media),
      without_media: flag(:without_media),
      without_bot: without_bot?,
      application: @application,
    }
  end

  def personal_options
    {
      only_media: flag(:only_media),
      without_media: flag(:without_media),
    }
  end

  def tag_list(key)
    Array(@context[key]).map { |value| clean_tag(value) }.compact
  end

  def clean_tag(value)
    text = value.to_s.strip.delete_prefix('#')
    return nil if text.blank? || text.length > 200

    text
  end

  def flag(key)
    return false unless @context.key?(key)

    ActiveModel::Type::Boolean.new.cast(@context[key])
  end

  def without_bot?
    return flag(:without_bot) if @context.key?(:without_bot)

    !!@user&.setting_hide_bot_on_public_timeline
  end

  def domain_available?(raw)
    normalized = TagManager.instance.normalize_domain(raw)
    return false if normalized.blank?

    Account.where(domain: normalized).without_suspended.without_silenced.exists?
  rescue Addressable::URI::InvalidURIError
    false
  end

  def retention_limitation
    "retention_#{FeedManager::MAX_ITEMS}"
  end
end
