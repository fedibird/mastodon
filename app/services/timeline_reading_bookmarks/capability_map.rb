# frozen_string_literal: true

module TimelineReadingBookmarks
  module CapabilityMap
    PRIVACY = {
      'home' => 'account',
      'limited' => 'account',
      'list' => 'owner_list',
      'personal' => 'account',
      'hashtag' => 'public',
      'public' => 'public',
      'domain' => 'public',
      'group' => 'group',
    }.freeze
    REDIS_SOURCES = %w(home limited list).freeze

    module_function

    def as_json(*)
      {
        version: 1,
        per_user_limit: TimelineReadingBookmark::PER_USER_LIMIT,
        name_max_length: TimelineReadingBookmark::NAME_MAX_LENGTH,
        anchor_version: 1,
        stores: %w(source context anchor name),
        rejects: %w(status_text search_text window view token),
        retention: { redis_max_items: FeedManager::MAX_ITEMS },
        sources: source_rows,
        # Account context seek is not a named bookmark. Keep it listed as closed here.
        closed_sources: %w(account) + TimelineSeek::Capability::CLOSED_SOURCES,
      }
    end

    def source_rows
      TimelineSeek::Capability::WINDOWED_SOURCES.index_with do |source|
        entry = TimelineSeek::Capability.lookup(source, 'status')
        {
          privacy: PRIVACY.fetch(source),
          capability: entry.level,
          reason: entry.reason,
          retention: REDIS_SOURCES.include?(source) ? 'redis_window' : 'database',
          anchor_membership: 'rechecked_on_restore',
        }
      end
    end
  end
end
