# frozen_string_literal: true

module TimelineSeek
  # Static source × kind matrix. Runtime can still downgrade a supported cell
  # (remote groups, an empty domain, a Redis miss). It must not upgrade one.
  module Capability
    VERSION = 1
    LEVELS = %w(supported approximate unavailable unsupported).freeze
    KINDS = %w(status date account searchHit).freeze
    WINDOWED_SOURCES = %w(home limited list hashtag public domain group personal).freeze
    CLOSED_SOURCES = %w(account direct notifications mix).freeze

    Entry = Struct.new(:level, :reason, keyword_init: true)

    REDIS_STATUS = Entry.new(level: 'approximate', reason: 'redis_retained_window').freeze
    REDIS_DATE = Entry.new(level: 'approximate', reason: 'redis_id_probe_not_created_at').freeze
    REDIS_ACCOUNT = Entry.new(level: 'approximate', reason: 'account_probe_limit').freeze
    REDIS_SEARCH = Entry.new(level: 'approximate', reason: 'search_hit_checks_retained_membership').freeze
    DB_STATUS = Entry.new(level: 'supported', reason: 'source_scope_point_lookup').freeze
    DB_DATE = Entry.new(level: 'approximate', reason: 'id_order_not_created_at').freeze
    DB_ACCOUNT = Entry.new(level: 'approximate', reason: 'account_probe_limit').freeze
    DB_SEARCH = Entry.new(level: 'supported', reason: 'search_hit_checks_membership_only').freeze
    PERSONAL_ACCOUNT = Entry.new(level: 'unsupported', reason: 'personal_is_not_an_account_timeline').freeze
    CLOSED = Entry.new(level: 'unsupported', reason: 'source_has_no_windowed_history').freeze
    UNKNOWN = Entry.new(level: 'unsupported', reason: 'unknown_source').freeze

    MATRIX = {
      'home' => { 'status' => REDIS_STATUS, 'date' => REDIS_DATE, 'account' => REDIS_ACCOUNT, 'searchHit' => REDIS_SEARCH },
      'limited' => { 'status' => REDIS_STATUS, 'date' => REDIS_DATE, 'account' => REDIS_ACCOUNT, 'searchHit' => REDIS_SEARCH },
      'list' => { 'status' => REDIS_STATUS, 'date' => REDIS_DATE, 'account' => REDIS_ACCOUNT, 'searchHit' => REDIS_SEARCH },
      'hashtag' => { 'status' => DB_STATUS, 'date' => DB_DATE, 'account' => DB_ACCOUNT, 'searchHit' => DB_SEARCH },
      'public' => { 'status' => DB_STATUS, 'date' => DB_DATE, 'account' => DB_ACCOUNT, 'searchHit' => DB_SEARCH },
      'domain' => { 'status' => DB_STATUS, 'date' => DB_DATE, 'account' => DB_ACCOUNT, 'searchHit' => DB_SEARCH },
      'group' => { 'status' => DB_STATUS, 'date' => DB_DATE, 'account' => DB_ACCOUNT, 'searchHit' => DB_SEARCH },
      'personal' => { 'status' => DB_STATUS, 'date' => DB_DATE, 'account' => PERSONAL_ACCOUNT, 'searchHit' => DB_SEARCH },
    }.freeze

    def self.lookup(source, kind)
      return CLOSED if CLOSED_SOURCES.include?(source.to_s)
      return UNKNOWN unless MATRIX.key?(source.to_s)

      MATRIX[source.to_s][kind.to_s] || Entry.new(level: 'unsupported', reason: 'unknown_kind')
    end
  end
end
