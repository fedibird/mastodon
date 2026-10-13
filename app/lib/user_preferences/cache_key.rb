# frozen_string_literal: true

module UserPreferences
  module CacheKey
    # String only. No database read, no Redis, no per-request memo.
    def self.for_revision(key, user, revision)
      "#{Setting.cache_key(key, user)}/rev/#{revision}"
    end
  end
end
