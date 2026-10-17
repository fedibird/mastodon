# frozen_string_literal: true

class SearchQueryTransformer < Parslet::Transform
  SUPPORTED_FILTER_PREFIXES = %w(
    has
    is
    not
    language
    lang
    from
    to
    by
    boosted_by
    before
    since
    after
    until
    during
    in
    min_replies
    min_reply
    min_boosts
    min_boost
    min_favs
    min_fav
    min_reactions
    min_reaction
    min_refs
    min_ref
    app
    client
    source
    generator
    domain
    url
  ).freeze

  SUPPORTED_ORDER_PREFIXES = %w(
    order
  ).freeze

  SUPPORTED_PREFIXES = SUPPORTED_FILTER_PREFIXES + SUPPORTED_ORDER_PREFIXES

  SUPPORTED_OPERATOR = %w(
    +
    -
  ).freeze

  SUPPORTED_PROPERTIES = (%w(
    image
    audio
    video
    media
    poll
    link
    embed
    sensitive
    reply
    quote
    ref
    bot
    expired
  ) + Status::visibilities.keys - %w(mutual)).freeze

  SUPPORTED_ORDER = %w(
    asc
    desc
  ).freeze

  SUPPORTED_SEARCHABLITY_FILTER = %w(
    all
    library
    public
    unlisted
    private
    follow
    mutual
    direct
  ).freeze

  class Query
    def initialize(clauses, options = {})
      raise ArgumentError if options[:current_account].nil?

      @clauses = clauses
      @options = options

      flags_from_clauses!
      lang_from_clauses!
    end
  
    def request
      searchability = @flags['in'] || @options[:searchability]

      raise "No support searchability: #{searchability}" unless SUPPORTED_SEARCHABLITY_FILTER.include?(searchability)

      case searchability
      when 'all'
        privacy_definition = StatusesIndex.filter(term: { searchable_by: @options[:current_account].id })
        privacy_definition = privacy_definition.or(StatusesIndex.filter(term: { searchability: 'public' }))
        privacy_definition = privacy_definition.or(StatusesIndex.filter(terms: { searchability: %w(unlisted private) }).filter(terms: { account_id: following_account_ids})) unless following_account_ids.empty?
      when 'unlisted', 'private'
        privacy_definition = StatusesIndex.filter(term: { searchable_by: @options[:current_account].id })
        privacy_definition = privacy_definition.or(StatusesIndex.filter(terms: { searchability: %w(public unlisted private) }).filter(terms: { account_id: following_account_ids})) unless following_account_ids.empty?
      when 'public'
        privacy_definition = StatusesIndex.filter(term: { searchability: 'public' })
      when 'follow'
        privacy_definition = StatusesIndex.none
        privacy_definition = StatusesIndex.filter(terms: { searchability: %w(public unlisted private) }).filter(terms: { account_id: following_account_ids}) unless following_account_ids.empty?
      when 'mutual'
        # StatusesIndex.none is dropped by Request#and, which would fall back to an unscoped search.
        privacy_definition = StatusesIndex.query(match_none: {})
        privacy_definition = StatusesIndex.filter(terms: { searchability: %w(public unlisted private) }).filter(terms: { account_id: mutual_account_ids }) unless mutual_account_ids.empty?
      else
        privacy_definition = StatusesIndex.filter(term: { searchable_by: @options[:current_account].id })
      end

      mute_definition = StatusesIndex.filter.must_not({terms: {account_id: @options[:current_account].excluded_from_timeline_account_ids}}).filter.must_not({terms: {domain: @options[:current_account].excluded_from_timeline_domains}})
  
      search = StatusesIndex

      must_clauses.each     { |clause| search = search.query.must(clause.to_query(@lang_stemmed)) }
      must_not_clauses.each { |clause| search = search.query.must_not(clause.to_query(@lang_stemmed)) }
      filter_clauses.each   { |clause| search = search.filter(**clause.to_query) }
      order_clauses.each    { |clause| search = search.order(**clause.to_query) }

      search.query.minimum_should_match(1).and(privacy_definition).and(mute_definition)
    end

    def clauses_by_operator
      @clauses_by_operator ||= @clauses.compact.group_by(&:operator)
    end

    def flags_from_clauses!
      @flags = clauses_by_operator.fetch(:flag, []).to_h { |clause| [clause.prefix, clause.term] }
    end

    def lang_from_clauses!
      @lang         = Array(clauses_by_operator.fetch(:filter, []).reverse.find { |clause| %w(language lang).include?(clause.prefix) }&.term).first || @options[:language]
      @lang_stemmed = %w(ja ko zh).include?(@lang) ? "text.#{@lang}_stemmed" : 'text.en_stemmed'
    end

    def must_clauses
      clauses_by_operator.fetch(:must, [])
    end

    def must_not_clauses
      clauses_by_operator.fetch(:must_not, [])
    end

    def filter_clauses
      clauses_by_operator.fetch(:filter, [])
    end

    def order_clauses
      clauses_by_operator.fetch(:order, [OrderPrefixClause.new('order', nil, 'desc')])
    end

    def following_account_ids
      return @following_account_ids if defined?(@following_account_ids)

      @following_account_ids = searchable_following_accounts.pluck(:target_account_id)
    end

    def mutual_account_ids
      return @mutual_account_ids if defined?(@mutual_account_ids)

      @mutual_account_ids = searchable_following_accounts.where("EXISTS (#{reverse_follow_exists_sql})").pluck(:target_account_id)
    end

    private

    def searchable_following_accounts
      account_exists_sql = Account.where('accounts.id = follows.target_account_id').where(searchability: %w(public unlisted private)).reorder(nil).select(1).to_sql
      status_exists_sql  = Status.where('statuses.account_id = follows.target_account_id').where(reblog_of_id: nil).where(searchability: %w(public unlisted private)).reorder(nil).select(1).to_sql

      Follow.where(account_id: @options[:current_account].id).merge(Account.where("EXISTS (#{account_exists_sql})").or(Account.where("EXISTS (#{status_exists_sql})")))
    end

    # Reverse Follow rows are established follows, not pending FollowRequests.
    def reverse_follow_exists_sql
      reverse = Follow.arel_table.alias('reverse_follows')
      follows = Follow.arel_table

      Follow.unscoped
            .reorder(nil)
            .from(reverse)
            .where(reverse[:account_id].eq(follows[:target_account_id]))
            .where(reverse[:target_account_id].eq(follows[:account_id]))
            .select(Arel.sql('1'))
            .to_sql
    end
  end

  class Operator
    class << self
      def symbol(str)
        case str
        when '+', nil
          :must
        when '-'
          :must_not
        else
          raise "Unknown operator: #{str}"
        end
      end
    end
  end

  class TermClause
    attr_reader :operator, :term

    def initialize(operator, term)
      @operator = Operator.symbol(operator)
      @term = term
    end

    def to_query(field)
      if @term.is_a?(Array)
        { bool: { must: { bool: { should: @term.map { |term| to_query_single(field, term) }, minimum_should_match: 1 } } } }
      else
        to_query_single(field, @term)
      end
    end

    private

    def to_query_single(field, term)
      if term.start_with?('#')
        { match: { tags: { query: term, operator: 'and' } } }
      else
        { match: { field => { query: term, operator: 'and' } } }
      end
    end
  end

  class PhraseClause
    attr_reader :operator, :phrase

    def initialize(operator, phrase)
      @operator = Operator.symbol(operator)
      @phrase = phrase
    end

    def to_query(field)
      if @phrase.is_a?(Array)
        { bool: { must: { bool: { should: @phrase.map { |phrase| { match_phrase: { text: { query: phrase } } } }, minimum_should_match: 1 } } } }
      else
        { match_phrase: { text: { query: @phrase } } }
      end
    end
  end

  class WildcardClause
    attr_reader :operator, :wildcard

    def initialize(operator, wildcard)
      @operator = Operator.symbol(operator)
      @wildcard = wildcard
    end

    def to_query(field)
      if @wildcard.is_a?(Array)
        { bool: { must: { bool: { should: @wildcard.map { |wildcard| { wildcard: { 'text.wildcard': { value: "*#{@wildcard}*", case_insensitive: true } } } }, minimum_should_match: 1 } } } }
      else
        { wildcard: { 'text.wildcard': { value: "*#{@wildcard}*", case_insensitive: true } } }
      end
    end
  end

  class PrefixClause
    attr_reader :operator, :prefix, :term

    MIN_COUNT_PREFIX = {
      'min_replies'   => :replies_count,
      'min_reply'     => :replies_count,
      'min_boosts'    => :reblogs_count,
      'min_boost'     => :reblogs_count,
      'min_favs'      => :favourites_count,
      'min_fav'       => :favourites_count,
      'min_reactions' => :emoji_reactions_count,
      'min_reaction'  => :emoji_reactions_count,
      'min_refs'      => :status_referred_by_count,
      'min_ref'       => :status_referred_by_count,
    }.freeze
  
    def initialize(prefix, operator, term, options = {})
      @prefix = prefix
      @negated = operator == '-'
      @options = options
      @operator = :filter

      case prefix
      when 'has', 'is', 'not'
        raise "No support property: #{prefix}" if Array(term).any? { |term| !SUPPORTED_PROPERTIES.include?(term) }

        @filter = :properties
        @type = term.is_a?(Array) ? :terms : :term
        @term = term
        @negated = !@negated if prefix === 'not'
      when 'language', 'lang'
        @filter = :language
        @type = term.is_a?(Array) ? :terms : :term
        # @term = language_code_from_term(term)
        @term = term
      when 'domain'
        @filter = :domain
        @type = term.is_a?(Array) ? :terms : :term
        @term = term
      when 'from'
        @filter = :account_id
        @type = term.is_a?(Array) ? :terms : :term
        @term = account_id_from_term(term)
      when 'to'
        @filter = :mentioned_account_id
        @type = term.is_a?(Array) ? :terms : :term
        @term = account_id_from_term(term)
      when 'by', 'boosted_by'
        @public_ids  = account_id_from_term(term, only_private: false)
        @private_ids = account_id_from_term(term, only_private: true)
        @term = { bool: { should: [
          {@public_ids.is_a?(Array)  ? :terms : :term => { public_reblogged_by_account_id: @public_ids }},
          {@private_ids.is_a?(Array) ? :terms : :term => { private_reblogged_by_account_id: @private_ids }},
        ] }}
      when 'url'
        if term.is_a?(Array)
          @term = { bool: { should: term.map { |term| { prefix: { urls: { value: "#{term.start_with?('https://') ? '' : 'https://'}#{term}" } } } }, minimum_should_match: 1 } }
        else
          @filter = :urls
          @type = :prefix
          @term = { value: "#{term.start_with?('https://') ? '' : 'https://'}#{term}" }
        end
      when 'app', 'client', 'source', 'generator'
        if term.is_a?(Array)
          @term = { bool: { should: term.map { |term| { prefix: { generator: { value: term } } } }, minimum_should_match: 1 } }
        else
          @filter = :generator
          @type = :prefix
          @term = { value: term }
        end
      when 'before', 'until'
        raise "Multiple terms are not permitted: #{prefix}" if term.is_a?(Array)
        @filter = :created_at
        @type = :range
        @term = { lt: term, time_zone: @options[:current_account]&.user_time_zone || 'UTC' }
      when 'after', 'since'
        raise "Multiple terms are not permitted: #{prefix}" if term.is_a?(Array)
        @filter = :created_at
        @type = :range
        @term = { gt: term, time_zone: @options[:current_account]&.user_time_zone || 'UTC' }
      when 'during'
        raise "Multiple terms are not permitted: #{prefix}" if term.is_a?(Array)
        @filter = :created_at
        @type = :range
        @term = { gte: term, lte: term, time_zone: @options[:current_account]&.user_time_zone || 'UTC' }
      when 'in'
        raise "Multiple terms are not permitted: #{prefix}" if term.is_a?(Array)
        @operator = :flag
        @term = term
      when *MIN_COUNT_PREFIX.keys
        raise "Multiple terms are not permitted: #{prefix}" if term.is_a?(Array)
        @filter = MIN_COUNT_PREFIX[prefix]
        @type = :range
        @term = { gte: term }
      else
        raise "Unknown prefix: #{prefix}"
      end
    end

    def to_query
      query = @type.nil? ? @term : { @type => { @filter => @term } }

      if @negated
        { bool: { must_not: query } }
      else
        query
      end
    end

    private

    def account_id_from_term(term, only_private: nil)
      return term.map { |term| account_id_from_term(term, only_private: only_private) } if term.is_a?(Array)

      return @options[:current_account]&.id || -1 if term == 'me'

      username, domain = term.gsub(/\A@/, '').split('@')
      domain = nil if TagManager.instance.local_domain?(domain)
      account = Account.find_remote(username, domain)

      return -1 if account.nil? ||
        only_private == true  && !(@options[:current_account]&.id == account.id || %w(public unlisted private).include?(account.searchability) && @options[:current_account]&.following?(account)) ||
        only_private == false && !(@options[:current_account]&.id == account.id || %w(public).include?(account.searchability))

      account.id
    end

    def language_code_from_term(term)
      language_code = term

      return language_code if LanguagesHelper::SUPPORTED_LOCALES.key?(language_code.to_sym)

      language_code = term.downcase

      return language_code if LanguagesHelper::SUPPORTED_LOCALES.key?(language_code.to_sym)

      language_code = term.split(/[_-]/).first.downcase

      return language_code if LanguagesHelper::SUPPORTED_LOCALES.key?(language_code.to_sym)

      term
    end
  end

  class OrderPrefixClause
    attr_reader :operator, :prefix, :term

    def initialize(prefix, operator, term, options = {})
      @prefix = prefix
      @negated = operator == '-'
      @options = options
      @operator = :order

      case prefix
      when 'order'
        raise "Unknown order: #{term}" unless SUPPORTED_ORDER.include?(term)

        @term = term
      else
        raise "Unknown prefix: #{prefix}"
      end
    end

    def to_query
      { created_at: @term }
    end
  end

  rule(clause: subtree(:clause)) do
    prefix   = clause[:prefix][:term].to_s.downcase if clause[:prefix]
    operator = clause[:operator]&.to_s
    term =
      if clause[:phrases]
        clause[:phrases].map { |phrase| clause[:phrase].is_a?(Array) ? phrase[:phrase].map { |phrase| phrase[:term].to_s }.join(' ') : nil }.compact
      elsif clause[:phrase]
        clause[:phrase].is_a?(Array) ? clause[:phrase].map { |term| term[:term].to_s }.join(' ') : nil
      elsif clause[:wildcards]
        clause[:wildcards].map { |wildcard| clause[:wildcard].is_a?(Array) ? wildcard[:wildcard].map { |wildcard| wildcard[:term].to_s }.join(' ') : nil }.compact
      elsif clause[:wildcard]
        clause[:wildcard].is_a?(Array) ? clause[:wildcard].map { |term| term[:term].to_s }.join(' ') : nil
      elsif clause[:terms]
        clause[:terms].map { |term| term[:term].to_s }
      elsif clause[:term]
        clause[:term].to_s
      else
        nil
      end

    if term.blank?
      nil
    elsif clause[:prefix] && SUPPORTED_FILTER_PREFIXES.include?(prefix)
      PrefixClause.new(prefix, operator, term, current_account: current_account)
    elsif clause[:prefix] && SUPPORTED_ORDER_PREFIXES.include?(prefix)
      OrderPrefixClause.new(prefix, operator, term, current_account: current_account)
    elsif clause[:prefix]
      TermClause.new(operator, "#{prefix} #{Array(term).join(' ')}")
    elsif clause[:phrases] || clause[:phrase]
      PhraseClause.new(operator, term)
    elsif clause[:wildcards] || clause[:wildcard]
      WildcardClause.new(operator, term)
    elsif term.present?
      TermClause.new(operator, term)
    else
      raise "Unexpected clause type: #{clause}"
    end
  end

  rule(junk: subtree(:junk)) do
    nil
  end

  rule(query: sequence(:clauses)) do
    Query.new(clauses, language: 'ja', current_account: current_account, searchability: searchability)
  end
end
