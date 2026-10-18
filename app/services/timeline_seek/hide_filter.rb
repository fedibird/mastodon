# frozen_string_literal: true

module TimelineSeek
  # Hide-action custom filters for this column, re-checked at request time.
  # Warn filters still leave the row visible, matching the column. The matched
  # keyword is not returned.
  class HideFilter
    # Same mapping as mastodon/utils/filters toServerSideType.
    CONTEXT = {
      'home' => 'home',
      'list' => 'home',
      'limited' => 'public',
      'public' => 'public',
      'hashtag' => 'public',
      'domain' => 'public',
      'group' => 'public',
      'personal' => 'public',
      'account' => 'account',
    }.freeze

    def initialize(account, source)
      @account = account
      @context = CONTEXT[source.to_s]
    end

    def hidden_ids(member_ids)
      return [] if member_ids.empty? || @account.nil? || @context.nil?

      filters = relevant
      return [] if filters.empty?

      hidden = []
      load_members(member_ids).each do |record|
        target = record.reblog || record
        hidden << record.id if CustomFilter.apply_cached_filters(filters, record, filterable_status: target).any?
      end
      hidden
    end

    private

    def relevant
      return [] if @account.nil? || @context.nil?

      CustomFilter.cached_filters_for(@account.id).select do |filter, rules|
        next false unless filter.hide_action? && Array(filter.context).include?(@context)

        rules[:keywords].present? || rules[:status_ids].present?
      end
    end

    def load_members(member_ids)
      Status.include_expired.where(id: member_ids).includes(:media_attachments, :references, :preloadable_poll, :reblog)
    end
  end
end
