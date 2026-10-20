# frozen_string_literal: true

class StatusesSearchService < BaseService
    def call(query, account = nil, options = {})
      @query         = query&.strip
      @account       = account
      @options       = options
      @limit         = options[:limit].to_i
      @offset        = options[:offset].to_i
      @searchability = options[:searchability] || convert_in_param(@account&.user&.setting_default_search_searchability) || 'private'
  
      convert_deprecated_options!
      status_search_results
    end
  
    private

    def convert_in_param(searchability)
      case searchability
      when 'public'
        'all'
      else
        searchability
      end
    end
  
    def status_search_results
      request           = parsed_query.request
      result_ids        = request.collapse(field: :id).limit(@limit).offset(@offset).pluck(:id).compact
      results           = Status.include_expired.where(id: result_ids).reorder(nil).order_as_specified(id: result_ids)
      account_ids       = results.map(&:account_id)
      account_relations = relations_map_for_account(@account&.id, account_ids)
      status_relations  = relations_map_for_status(@account&.id, results)
  
      decision = ExternalBridge::ProjectionAccess::Decision.for(results, ExternalBridge::Viewer.user_id)
      results.reject { |status| StatusFilter.new(status, @account, account_relations, status_relations, include_expired: true, projection_decision: decision).filtered? }
    rescue Faraday::ConnectionFailed, Parslet::ParseFailed
      []
    end
  
    def relations_map_for_account(account_id, account_ids)
      presenter = AccountRelationshipsPresenter.new(account_ids, account_id)
      {
        blocking: presenter.blocking,
        blocked_by: presenter.blocked_by,
        muting: presenter.muting,
        following: presenter.following,
        domain_blocking_by_domain: presenter.domain_blocking,
      }
    end
  
    def relations_map_for_status(account_id, statuses)
      presenter = StatusRelationshipsPresenter.new(statuses, account_id)
      {
        reblogs_map: presenter.reblogs_map,
        favourites_map: presenter.favourites_map,
        bookmarks_map: presenter.bookmarks_map,
        emoji_reactions_map: presenter.emoji_reactions_map,
        mutes_map: presenter.mutes_map,
        pins_map: presenter.pins_map,
      }
    end

    def parsed_query
      SearchQueryTransformer.new.apply(SearchQueryParser.new.parse(@query), current_account: @account, searchability: @searchability)
    end
  
    def convert_deprecated_options!
      syntax_options = []
  
      if @options[:account_id]
        username = Account.select(:username, :domain).find(@options[:account_id]).acct
        syntax_options << "from:@#{username}"
      end
  
      if @options[:min_id]
        timestamp = Mastodon::Snowflake.to_time(@options[:min_id].to_i)
        syntax_options << "after:\"#{timestamp.iso8601}\""
      end
  
      if @options[:max_id]
        timestamp = Mastodon::Snowflake.to_time(@options[:max_id].to_i)
        syntax_options << "before:\"#{timestamp.iso8601}\""
      end
  
      @query = "#{@query} #{syntax_options.join(' ')}".strip if syntax_options.any?
    end
  end
