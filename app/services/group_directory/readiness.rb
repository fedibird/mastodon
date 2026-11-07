# frozen_string_literal: true

# Whether GET /api/v1/group_directory may read GroupDirectoryIndex.
#
# GROUP_DIRECTORY_ES_SEARCH is independent of GROUP_DIRECTORY_INDEX and
# defaults off. When it is off, Listing keeps the SQL query. When it is on,
# every readiness condition has to hold. A missing index, a rebuild that
# has not finished, a stopped cluster, or a version gap raises
# SearchUnavailable. Nothing in that failure path runs the SQL search.
class GroupDirectory::Readiness
  class << self
    def search_enabled?
      enabled?('GROUP_DIRECTORY_ES_SEARCH')
    end

    def ensure_available!
      raise GroupDirectory::SearchUnavailable, 'ES_ENABLED is not true' unless Chewy.enabled?
      raise GroupDirectory::SearchUnavailable, 'GROUP_DIRECTORY_INDEX is not true' unless enabled?('GROUP_DIRECTORY_INDEX')
      raise GroupDirectory::SearchUnavailable, 'group directory index is missing' unless GroupDirectory::Indexing.index_ready?
      raise GroupDirectory::SearchUnavailable, 'group directory index backfill is incomplete' unless GroupDirectory::Indexing.backfill_complete?
      raise GroupDirectory::SearchUnavailable, 'group directory index version gap' if GroupDirectory::Indexing.version_gap?
    rescue GroupDirectory::SearchUnavailable
      raise
    rescue StandardError => e
      raise GroupDirectory::SearchUnavailable, "readiness check failed: #{e.class}"
    end

    private

    def enabled?(name)
      ActiveModel::Type::Boolean.new.cast(ENV[name]) == true
    end
  end
end
