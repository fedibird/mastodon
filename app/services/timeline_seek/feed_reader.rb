# frozen_string_literal: true

module TimelineSeek
  # One page of an existing timeline feed. Membership is `get(1, id + 1)`,
  # which is the same id-desc LIMIT the timeline already uses. Redis membership
  # is a ZSCORE on the retained ZSET, not a scan of the whole key.
  class FeedReader
    attr_reader :visibilities, :redis_key, :unfiltered

    def initialize(feed, external: nil, compose: nil, **options)
      @feed = feed
      @external = external
      @compose = compose
      @visibilities = options[:visibilities]
      @redis_key = options[:redis_key]
      @redis = options[:redis]
      @regenerating = options[:regenerating]
      @empty = options[:empty]
      @unfiltered = options[:unfiltered]
    end

    def redis?
      redis_key.present?
    end

    def regenerating?
      @regenerating
    end

    def empty_source?
      @empty || @feed.nil?
    end

    def page(limit, max_id: nil, min_id: nil)
      return [] if empty_source?

      if @compose
        @compose.call(limit, max_id, nil, min_id, visibilities || [])
      elsif visibilities
        @feed.get(limit, max_id, nil, min_id, visibilities)
      else
        @feed.get(limit, max_id, nil, min_id)
      end
    end

    def external?
      !@external.nil?
    end

    # DB membership for this user's projections. Ordinary ids are absent.
    def external_partition(status_ids)
      return ExternalBridge::Feeds::Placement.empty if @external.nil?

      @external.partition(status_ids)
    end

    # Integer ids have no value between n and n + 1, so the newest row with
    # id < n + 1 is n exactly when n is in this feed's scope.
    def contains?(status_id)
      return false if empty_source? || status_id.nil?
      return @feed.contains_id?(status_id) if @feed.respond_to?(:contains_id?)

      page(1, max_id: status_id.to_i + 1).first&.id == status_id.to_i
    end

    def remote_account?
      @feed.respond_to?(:remote_account?) && @feed.remote_account?
    end

    def in_retained_set?(status_id)
      return false unless redis? && @redis

      !@redis.zscore(redis_key, status_id).nil?
    end

    def selectable?(status_id)
      scope = Status.where(id: status_id).without_unreleased_pages.joins(:account).merge(Account.without_suspended)
      scope = scope.where(visibility: visibilities) if visibilities.present?
      scope.limit(1).exists?
    end

    def retained_count
      return 0 unless redis? && @redis

      @redis.zcard(redis_key).to_i
    end

    # One id-set query. The caller caps the array; limit is a second bound.
    def scope_ids(status_ids, limit:)
      return [] if empty_source? || status_ids.empty? || redis?
      return @feed.scope_ids(status_ids, limit: limit) if @feed.respond_to?(:scope_ids)
      return [] unless @feed.respond_to?(:relation)

      ids = status_ids.first(limit)
      @feed.relation.where(statuses: { id: ids }).unscope(:order).distinct.limit(limit).pluck(Status.arel_table[:id])
    end

    def retained_ids(status_ids)
      return [] unless redis? && @redis && status_ids.any?

      TimelineSeek::RedisBulkScore.new(@redis).present_ids(redis_key, status_ids)
    end

    # Same predicate as selectable?, for the whole id set.
    def selectable_among(status_ids, limit:)
      ids = status_ids.first(limit)
      return [] if ids.empty?

      scope = Status.where(id: ids).without_unreleased_pages.joins(:account).merge(Account.without_suspended)
      scope = scope.where(visibility: visibilities) if visibilities.present?
      scope.limit(limit).pluck(:id)
    end
  end
end
