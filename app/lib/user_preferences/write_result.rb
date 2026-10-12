# frozen_string_literal: true

class UserPreferences::WriteResult
  attr_reader :before, :after, :changed_keys, :unchanged_keys, :cache_deleted

  def initialize(before:, after:, changed_keys:, unchanged_keys:, cache_deleted:)
    @before = before
    @after = after
    @changed_keys = changed_keys.dup.freeze
    @unchanged_keys = unchanged_keys.dup.freeze
    @cache_deleted = cache_deleted.dup.freeze
    freeze
  end
end
