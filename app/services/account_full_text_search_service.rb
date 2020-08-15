# frozen_string_literal: true

class AccountFullTextSearchService < BaseService
  def call(query, account, limit, options = {})
    @query   = query&.strip
    @account = account
    @options = options
    @limit   = limit.to_i
    @offset  = options[:offset].to_i

    return if @query.blank? || @limit.zero?

    perform_account_text_search!
  end

  private

  def perform_account_text_search!
    definition = parsed_query.apply(AccountsIndex.filter(term: { discoverable: true }))

    results             = definition.limit(@limit).offset(@offset).objects.compact
    account_ids         = results.map(&:id)
    account_domains     = results.map(&:domain).uniq.compact
    preloaded_relations = relations_map_for_account(@account, account_ids, account_domains)

    results.reject { |target_account| AccountFilter.new(target_account, @account, preloaded_relations).filtered? }
  rescue Faraday::ConnectionFailed, Parslet::ParseFailed
    []
  end

  def relations_map_for_account(account, account_ids, domains)
    {
      blocking: Account.blocking_map(account_ids, account.id),
      blocked_by: Account.blocked_by_map(account_ids, account.id),
      muting: Account.muting_map(account_ids, account.id),
      following: Account.following_map(account_ids, account.id),
      domain_blocking_by_domain: Account.domain_blocking_map_by_domain(domains, account.id),
    }
  end

  def parsed_query
    SearchQueryTransformer.new.apply(SearchQueryParser.new.parse(@query))
  end
end
