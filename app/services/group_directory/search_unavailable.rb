# frozen_string_literal: true

# The Elasticsearch read path could not answer. Callers render 503 and do
# not fall back to the SQL ILIKE listing. `reason` is for logs only.
class GroupDirectory::SearchUnavailable < Mastodon::Error
  attr_reader :reason

  def initialize(reason)
    @reason = reason.to_s
    super('Group directory search is temporarily unavailable')
  end
end
