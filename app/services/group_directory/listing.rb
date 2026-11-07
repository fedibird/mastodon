# frozen_string_literal: true

# Entry point for GET /api/v1/group_directory.
#
# Parameters are parsed first, so a bad request is 400 even when
# Elasticsearch is down. GROUP_DIRECTORY_ES_SEARCH stays off unless an
# operator sets it. The off path is GroupDirectory::Query. The on path
# reads the index and does not catch errors into the SQL search.
class GroupDirectory::Listing
  def initialize(viewer:, params:, limit:)
    @viewer = viewer
    @params = params
    @limit = limit
  end

  def results
    parsed = GroupDirectory::Parameters.parse!(@params)
    return Account.none if blank_result?(parsed)

    if GroupDirectory::Readiness.search_enabled?
      GroupDirectory::Readiness.ensure_available!
      return GroupDirectory::ElasticsearchQuery.new(viewer: @viewer, parsed: parsed, limit: @limit).results
    end

    GroupDirectory::Query.new(viewer: @viewer, params: @params, limit: @limit, parsed: parsed).results
  end

  private

  def blank_result?(parsed)
    parsed.empty_result? || (parsed.following? && @viewer.nil?)
  end
end
