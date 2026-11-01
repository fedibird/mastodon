# frozen_string_literal: true

# Listing query for GET /api/v1/group_directory.
#
# A Group actor is not proof of a conversation community. PeerTube video
# channels are left out only when NodeInfo itself reports software_name
# peertube. A missing, blank, or unrecognized name is not treated as PeerTube.
#
# Languages are rows in group_languages. This query never copies NodeInfo
# languages, the viewer's UI locale, or the language of a post. A specific
# tag matches only groups that declared it. "unset" matches groups with no
# declared tags, not every group.
#
# order=new is the existing id order (when this server stored the row), not
# the group's created_at. Software is a NodeInfo self-report, not a promise
# that the viewer can post.
#
# Search has two paths. A handle (@name, @name@domain, name@domain) matches
# username and domain exactly, including a local account looked up by this
# server's domain, and does not also run a leading-wildcard scan. Any other
# query of at least two characters matches name, handle, domain, and
# description, with % and _ as literals. One character that is not a
# username matches nothing. /api is already covered by the Rack::Attack API
# throttles. The nodes.info GIN index does not serve
# LOWER(info->>'software_name'); that predicate stays a filter on Node rows.
class GroupDirectory::Query
  MAX_QUERY_LENGTH = 100
  MIN_SUBSTRING_LENGTH = 2
  MAX_SOFTWARE_LENGTH = 40
  MAX_LANGUAGE_LENGTH = 35
  # The directory API still pages with offset. Past this point a large OFFSET
  # walks the candidate index, so the request is rejected. A cursor can
  # replace this later; this query does not add one.
  MAX_OFFSET = 10_000
  ORDERS = %w(active new).freeze
  SCOPES = %w(all local following).freeze
  PEERTUBE = 'peertube'
  KNOWN_SOFTWARE = %w(fedibird lemmy piefed nodebb mbin mitra).freeze
  SOFTWARE_PATTERN = /\A[a-z0-9][a-z0-9_.-]*\z/
  ACCT_WITH_DOMAIN = /\A@?(?<username>#{Account::USERNAME_RE})@(?<domain>[^@\s]+)\z/i
  ACCT_USERNAME = /\A@(?<username>#{Account::USERNAME_RE})\z/i

  def initialize(viewer:, params:, limit:)
    @viewer = viewer
    @params = params
    @limit = limit
  end

  def results
    scope = Account.discoverable.groups.where(domain_clause)
    scope = exclude_viewer_accounts(scope)
    scope = apply_search(scope)
    scope = apply_software(scope)
    scope = apply_listing_scope(scope)
    scope = apply_language(scope)
    apply_order(scope).offset(offset_value).limit(@limit).preload(:node, :group_languages)
  end

  private

  # One domain predicate. Merging Account.not_domain_blocked_by_account
  # would replace this OR on Rails 7 and could drop the PeerTube exclusion.
  def domain_clause
    nodes = Node.has_nodeinfo.where("#{software_sql} <> ?", PEERTUBE)
    table = Account.arel_table
    remote = table[:domain].in(nodes.select(:domain).arel)
    blocked = @viewer&.excluded_from_timeline_domains
    remote = remote.and(table[:domain].not_in(blocked)) if blocked.present?
    table[:domain].eq(nil).or(remote)
  end

  def exclude_viewer_accounts(scope)
    return scope if @viewer.nil?

    hidden = @viewer.excluded_from_timeline_account_ids
    return scope if hidden.blank?

    scope.where.not(id: hidden)
  end

  def apply_search(scope)
    query = string_param(:q, MAX_QUERY_LENGTH)
    return scope if query.nil?

    if (acct = exact_acct(query))
      binds = { acct_username: acct[:username] }
      binds[:acct_domain] = acct[:domain] if acct[:domain_constrained]
      return scope.where(acct_clause(acct), binds)
    end

    return scope.none if query.length < MIN_SUBSTRING_LENGTH

    scope.where(substring_clause, pattern: "%#{Account.sanitize_sql_like(query)}%")
  end

  def apply_software(scope)
    software = string_param(:software, MAX_SOFTWARE_LENGTH)&.downcase
    return scope if software.nil?

    invalid!('software') unless SOFTWARE_PATTERN.match?(software)

    case software
    when 'fedibird'
      scope.where(local_or_domains(software_nodes('fedibird')))
    # Present NodeInfo with no software_name. Missing NodeInfo stays out of
    # the directory, including this filter. That is the existing listing
    # rule. unknown does not mean every unrecognized or unfetched domain.
    when 'unknown'
      scope.where(domain: Node.has_nodeinfo.where("#{blank_software_sql} = ''").select(:domain))
    when 'other'
      known = KNOWN_SOFTWARE + [PEERTUBE]
      scope.where(domain: Node.has_nodeinfo.where("#{software_sql} NOT IN (?) AND #{blank_software_sql} <> ''", known).select(:domain))
    else
      scope.where(domain: software_nodes(software).select(:domain))
    end
  end

  def apply_listing_scope(scope)
    listing = string_param(:scope, 16)&.downcase || 'all'
    invalid!('scope') unless SCOPES.include?(listing)
    return scope.where(domain: nil) if listing == 'local'
    return scope if listing == 'all'
    return scope.none if @viewer.nil?

    scope.where(id: Follow.where(account_id: @viewer.id).select(:target_account_id))
  end

  def apply_language(scope)
    language = string_param(:language, MAX_LANGUAGE_LENGTH)
    return scope if language.nil? || language.casecmp('all').zero?
    return scope.where.not(id: GroupLanguage.select(:account_id)) if language.casecmp('unset').zero?

    tag = GroupDirectory::Languages.canonicalize(language)
    invalid!('language') if tag.nil?
    scope.where(id: GroupLanguage.where(tag: tag).select(:account_id))
  end

  # active stays on Account.by_recent_status so this list keeps the existing
  # activity order. new is id desc, which is when this server stored the row.
  def apply_order(scope)
    order = string_param(:order, 16)&.downcase || 'active'
    invalid!('order') unless ORDERS.include?(order)
    return scope.reorder(id: :desc) if order == 'new'

    scope.merge(Account.by_recent_status)
  end

  def offset_value
    value = @params[:offset]
    return 0 if value.nil?
    return 0 if value.is_a?(String) && value.strip.empty?

    invalid!('offset') unless value.is_a?(String) && value.match?(/\A\d{1,5}\z/)
    number = value.to_i
    invalid!('offset') if number > MAX_OFFSET
    number
  end

  def string_param(name, max_length)
    value = @params[name]
    return if value.nil?

    invalid!(name.to_s) unless value.is_a?(String) && value.length <= max_length
    value.strip.presence
  end

  def local_or_domains(nodes)
    table = Account.arel_table
    table[:domain].eq(nil).or(table[:domain].in(nodes.select(:domain).arel))
  end

  def software_nodes(name)
    Node.has_nodeinfo.where("#{software_sql} = ?", name)
  end

  # @name matches that username on every domain. name@domain and
  # @name@domain also constrain the domain. This server's own domain means
  # the local row, whose domain column is null.
  def exact_acct(query)
    if (match = query.match(ACCT_WITH_DOMAIN))
      domain = acct_domain(match[:domain])
      return if domain.nil?

      return { username: match[:username].downcase, domain: domain, domain_constrained: true }
    end

    if (match = query.match(ACCT_USERNAME))
      return { username: match[:username].downcase, domain_constrained: false }
    end

    return unless query.length < MIN_SUBSTRING_LENGTH && Account::USERNAME_ONLY_RE.match?(query)

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

  def acct_clause(acct)
    sql = 'lower((accounts.username)::text) = :acct_username'
    return sql unless acct[:domain_constrained]

    "(#{sql} AND COALESCE(lower((accounts.domain)::text), '') = :acct_domain)"
  end

  def substring_clause
    <<~SQL.squish
      (accounts.display_name ILIKE :pattern
      OR accounts.username ILIKE :pattern
      OR accounts.domain ILIKE :pattern
      OR accounts.note ILIKE :pattern
      OR (accounts.username || COALESCE('@' || accounts.domain, '')) ILIKE :pattern)
    SQL
  end

  def software_sql
    "LOWER(BTRIM(COALESCE(nodes.info->>'software_name', '')))"
  end

  def blank_software_sql
    "BTRIM(COALESCE(nodes.info->>'software_name', ''))"
  end

  def invalid!(name)
    raise Mastodon::InvalidParameterError, "Invalid #{name}"
  end
end
