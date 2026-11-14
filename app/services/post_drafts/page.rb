# frozen_string_literal: true

module PostDrafts
  class Page
    DEFAULT_LIMIT = 20
    MAX_LIMIT = 40

    def initialize(account, params)
      @account = account
      @params = params
    end

    def records
      @records ||= bounded
    end

    def more?
      records
      @more
    end

    def limit
      raw = @params[:limit].to_i
      value = raw.positive? ? raw : DEFAULT_LIMIT
      [value, MAX_LIMIT].min
    end

    private

    def bounded
      rows = filtered.limit(limit + 1).to_a
      @more = rows.size > limit
      rows.first(limit)
    end

    def owned
      PostDraft.where(account_id: @account.id)
    end

    def filtered
      scope = owned.order(updated_at: :desc, id: :desc)
      return scope if @params[:max_id].blank?

      cursor = owned.find_by(id: @params[:max_id])
      return scope.none if cursor.nil?

      scope.where(
        'post_drafts.updated_at < :updated_at OR (post_drafts.updated_at = :updated_at AND post_drafts.id < :id)',
        updated_at: cursor.updated_at,
        id: cursor.id
      )
    end
  end
end
