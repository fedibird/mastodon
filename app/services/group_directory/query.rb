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
# server's domain, and does not also run a leading-wildcard scan. A handle
# whose domain cannot be normalized matches nothing. Any other query of at
# least two characters matches name, handle, domain, and description, with
# % and _ as literals. One character that is not a username matches nothing;
# the search form explains that names and descriptions need two characters.
# /api is already covered by the Rack::Attack API throttles. The nodes.info
# GIN index does not serve LOWER(info->>'software_name'); that predicate
# stays a filter on Node rows. A two-character ILIKE, including note, is
# still a filter on the discoverable-group index. This tree has no
# production-sized measurement of that filter.
#
# Listing uses this class while GROUP_DIRECTORY_ES_SEARCH is off. The flag
# is off unless an operator sets it. This class does not call Elasticsearch.
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
  PEERTUBE = GroupDirectory::Eligibility::PEERTUBE
  KNOWN_SOFTWARE = GroupDirectory::Eligibility::KNOWN_SOFTWARE
  SOFTWARE_PATTERN = /\A[a-z0-9][a-z0-9_.-]*\z/
  ACCT_WITH_DOMAIN = /\A@?(?<username>#{Account::USERNAME_RE})@(?<domain>[^@\s]+)\z/i
  ACCT_USERNAME = /\A@(?<username>#{Account::USERNAME_RE})\z/i

  def initialize(viewer:, params:, limit:, parsed: nil)
    @viewer = viewer
    @params = params
    @limit = limit
    @parsed = parsed
  end

  def results
    @parsed ||= GroupDirectory::Parameters.parse!(@params)
    scope = Account.discoverable.groups.where(domain_clause)
    scope = exclude_viewer_accounts(scope)
    scope = apply_search(scope)
    scope = apply_software(scope)
    scope = apply_listing_scope(scope)
    scope = apply_language(scope)
    apply_order(scope).offset(@parsed.offset).limit(@limit).preload(:node, :group_languages)
  end

  private

  # One domain predicate. Merging Account.not_domain_blocked_by_account
  # would replace this OR on Rails 7 and could drop the PeerTube exclusion.
  def domain_clause
    table = Account.arel_table
    remote = table[:domain].in(GroupDirectory::Eligibility.remote_domains.select(:domain).arel)
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
    return scope if @parsed.query.nil?
    return scope.none if @parsed.rejected_handle?

    if @parsed.exact?
      acct = @parsed.acct
      binds = { acct_username: acct[:username] }
      binds[:acct_domain] = acct[:domain] if acct[:domain_constrained]
      return scope.where(acct_clause(acct), binds)
    end

    return scope.none if @parsed.query.length < MIN_SUBSTRING_LENGTH

    scope.where(substring_clause, pattern: "%#{Account.sanitize_sql_like(@parsed.query)}%")
  end

  def apply_software(scope)
    software = @parsed.software
    return scope if software.nil?

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
    return scope.where(domain: nil) if @parsed.scope == 'local'
    return scope if @parsed.scope == 'all'
    return scope.none if @viewer.nil?

    scope.where(id: Follow.where(account_id: @viewer.id).select(:target_account_id))
  end

  def apply_language(scope)
    case @parsed.language
    when nil
      scope
    when :unset
      scope.where.not(id: GroupLanguage.select(:account_id))
    else
      scope.where(id: GroupLanguage.where(tag: @parsed.language).select(:account_id))
    end
  end

  # active stays on Account.by_recent_status so this list keeps the existing
  # activity order. new is id desc, which is when this server stored the row.
  def apply_order(scope)
    return scope.reorder(id: :desc) if @parsed.order == 'new'

    scope.merge(Account.by_recent_status)
  end

  def local_or_domains(nodes)
    table = Account.arel_table
    table[:domain].eq(nil).or(table[:domain].in(nodes.select(:domain).arel))
  end

  def software_nodes(name)
    Node.has_nodeinfo.where("#{software_sql} = ?", name)
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
    GroupDirectory::Eligibility::SOFTWARE_NAME_SQL
  end

  def blank_software_sql
    "BTRIM(COALESCE(nodes.info->>'software_name', ''))"
  end
end
