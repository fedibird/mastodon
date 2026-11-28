# frozen_string_literal: true

# Shared parameter contract for the SQL and Elasticsearch directory paths.
#
# Invalid values raise Mastodon::InvalidParameterError before either path
# touches Elasticsearch or runs a search query. Both paths read the parsed
# object so a handle, a one-character lookup, software, language, scope,
# order, and offset mean the same thing.
class GroupDirectory::Parameters
  REJECTED_HANDLE = :rejected_handle

  attr_reader :query, :acct, :software, :language, :scope, :order, :offset

  def self.parse!(params)
    new(params).tap(&:parse!)
  end

  def initialize(params)
    @params = params
  end

  def parse!
    @query = string_param(:q, GroupDirectory::Query::MAX_QUERY_LENGTH)
    @acct = exact_acct(@query) if @query
    @software = normalize_software
    @language = normalize_language
    @scope = normalize_scope
    @order = normalize_order
    @offset = normalize_offset
    self
  end

  def rejected_handle?
    @acct == REJECTED_HANDLE
  end

  def exact?
    @acct.is_a?(Hash)
  end

  def substring?
    @query.present? && !exact? && !rejected_handle? && @query.length >= GroupDirectory::Query::MIN_SUBSTRING_LENGTH
  end

  # A result that is empty by the parameter rules, before any index lookup.
  # Anonymous following depends on the viewer and is decided by Listing.
  def empty_result?
    rejected_handle? || (@query.present? && !exact? && @query.length < GroupDirectory::Query::MIN_SUBSTRING_LENGTH)
  end

  def following?
    @scope == 'following'
  end

  private

  def normalize_software
    software = string_param(:software, GroupDirectory::Query::MAX_SOFTWARE_LENGTH)&.downcase
    return if software.nil?

    invalid!('software') unless GroupDirectory::Query::SOFTWARE_PATTERN.match?(software)
    software
  end

  def normalize_language
    language = string_param(:language, GroupDirectory::Query::MAX_LANGUAGE_LENGTH)
    return if language.nil? || language.casecmp('all').zero?
    return :unset if language.casecmp('unset').zero?

    tag = GroupDirectory::Languages.canonicalize(language)
    invalid!('language') if tag.nil?
    tag
  end

  def normalize_scope
    listing = string_param(:scope, 16)&.downcase || 'all'
    invalid!('scope') unless GroupDirectory::Query::SCOPES.include?(listing)
    listing
  end

  def normalize_order
    order = string_param(:order, 16)&.downcase || 'active'
    invalid!('order') unless GroupDirectory::Query::ORDERS.include?(order)
    order
  end

  def normalize_offset
    value = @params[:offset]
    return 0 if value.nil?
    return 0 if value.is_a?(String) && value.strip.empty?

    invalid!('offset') unless value.is_a?(String) && value.match?(/\A\d{1,5}\z/)
    number = value.to_i
    invalid!('offset') if number > GroupDirectory::Query::MAX_OFFSET
    number
  end

  def string_param(name, max_length)
    value = @params[name]
    return if value.nil?

    invalid!(name.to_s) unless value.is_a?(String) && value.length <= max_length
    value.strip.presence
  end

  # @name matches that username on every domain. name@domain and
  # @name@domain also constrain the domain. This server's own domain means
  # the local row, whose domain column is null. A one-character username
  # is an exact username match. A longer query is not rewritten into one.
  def exact_acct(query)
    if (match = query.match(GroupDirectory::Query::ACCT_WITH_DOMAIN))
      domain = acct_domain(match[:domain])
      return REJECTED_HANDLE if domain.nil?

      return { username: match[:username].downcase, domain: domain, domain_constrained: true }
    end

    if (match = query.match(GroupDirectory::Query::ACCT_USERNAME))
      return { username: match[:username].downcase, domain_constrained: false }
    end

    return unless query.length < GroupDirectory::Query::MIN_SUBSTRING_LENGTH && Account::USERNAME_ONLY_RE.match?(query)

    { username: query.downcase, domain_constrained: false }
  end

  def acct_domain(domain)
    return '' if TagManager.instance.local_domain?(domain)

    normalized = TagManager.instance.normalize_domain(domain)
    return if normalized.blank?
    return '' if TagManager.instance.local_domain?(normalized)

    normalized
  rescue Addressable::URI::InvalidURIError, IDN::Idna::IdnaError
    nil
  end

  def invalid!(name)
    raise Mastodon::InvalidParameterError, "Invalid #{name}"
  end
end
