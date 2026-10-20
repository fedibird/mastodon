# frozen_string_literal: true

class FilterMatchesService < BaseService
  LIMIT = 100
  MAX_ID = '9223372036854775807'
  TEXT_ASSOCIATIONS = [:account, :mentions, :preloadable_poll, :media_attachments, { references: :account }].freeze

  def call(account, input)
    ids = validate_ids!(input)
    return { matches: {}, unavailable: [] } if ids.empty?

    # Do not use relations_map_for_status: its full presenter also evaluates
    # filters before authorization and fetches unrelated timeline relationships.
    statuses = Status.where(id: ids).includes(*TEXT_ASSOCIATIONS, reblog: TEXT_ASSOCIATIONS).to_a
    records = (statuses + statuses.filter_map(&:reblog)).uniq(&:id)
    ExternalBridge::ProjectionAccess.prepare!(records)
    relations = Status.relations_map_for_account(account.id, records.map(&:account_id).uniq)
    filters = CustomFilter.cached_filters_for(account.id)
    matches = statuses.each_with_object({}) do |status, result|
      next unless viewable?(account, status, relations)
      next if status.reblog_of_id.present? && (status.reblog.nil? || !viewable?(account, status.reblog, relations))

      result[status.id.to_s] = CustomFilter.apply_cached_filters(filters, status, filterable_status: status.reblog || status).map { |match| match.filter.id.to_s }.uniq
    end

    { matches: ids.select { |id| matches.key?(id) }.index_with { |id| matches[id] }, unavailable: ids.reject { |id| matches.key?(id) } }
  end

  private

  def viewable?(account, status, relations)
    StatusPolicy.new(account, status, relations).show? && !StatusFilter.new(status, account, relations).filtered?
  end

  def validate_ids!(input)
    valid = input.is_a?(Array) && input.size <= LIMIT && input.all? do |id|
      id.is_a?(String) && id.bytesize <= MAX_ID.size && /\A[1-9][0-9]*\z/.match?(id) && (id.size < MAX_ID.size || id <= MAX_ID)
    end
    raise Mastodon::ValidationError, 'status_ids must be an array of at most 100 positive bigint ID strings' unless valid

    input.uniq
  end
end
