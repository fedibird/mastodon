# frozen_string_literal: true

# Listing query for GET /api/v1/group_directory.
#
# A Group actor is not proof of a conversation community. PeerTube video
# channels are left out only when NodeInfo itself reports software_name
# peertube. A missing, blank, or unrecognized name is not treated as PeerTube.
#
# Languages are explicit group metadata. This query never copies NodeInfo
# languages, the viewer's UI locale, or the language of a post. Until a group
# declares tags, a specific language matches nobody and "unset" matches the
# same rows as "all".
#
# order=new is the existing id order (when this server stored the row), not
# the group's created_at. Software is a NodeInfo self-report, not a promise
# that the viewer can post.
class GroupDirectory::Query
  MAX_QUERY_LENGTH = 100
  MAX_SOFTWARE_LENGTH = 40
  MAX_LANGUAGE_LENGTH = 35
  MAX_OFFSET = 10_000
  ORDERS = %w(active new).freeze
  SCOPES = %w(all local following).freeze
  PEERTUBE = 'peertube'
  KNOWN_SOFTWARE = %w(fedibird lemmy piefed nodebb mbin mitra).freeze
  SOFTWARE_PATTERN = /\A[a-z0-9][a-z0-9_.-]*\z/
  LANGUAGE_PATTERN = /\A[a-z]{2,3}(?:-[0-9A-Za-z]{2,8}){0,3}\z/
  ACTIVE_ORDER = Arel.sql('(CASE WHEN account_stats.last_status_at IS NULL THEN 1 ELSE 0 END) ASC, account_stats.last_status_at DESC, accounts.id DESC')

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
    scope.order(order_clause).offset(offset_value).limit(@limit).preload(:node)
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

    pattern = "%#{Account.sanitize_sql_like(query)}%"
    scope.where(
      <<~SQL.squish,
        accounts.display_name ILIKE :pattern
        OR accounts.username ILIKE :pattern
        OR accounts.note ILIKE :pattern
        OR (accounts.username || COALESCE('@' || accounts.domain, '')) ILIKE :pattern
      SQL
      pattern: pattern
    )
  end

  def apply_software(scope)
    software = string_param(:software, MAX_SOFTWARE_LENGTH)&.downcase
    return scope if software.nil?

    invalid!('software') unless SOFTWARE_PATTERN.match?(software)

    case software
    when 'fedibird'
      scope.where(local_or_domains(software_nodes('fedibird')))
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
    return scope if language.casecmp('unset').zero?

    invalid!('language') if canonical_language(language).nil?
    scope.none
  end

  def order_clause
    order = string_param(:order, 16)&.downcase || 'active'
    invalid!('order') unless ORDERS.include?(order)
    return Arel.sql('accounts.id DESC') if order == 'new'

    ACTIVE_ORDER
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

  def software_sql
    "LOWER(BTRIM(COALESCE(nodes.info->>'software_name', '')))"
  end

  def blank_software_sql
    "BTRIM(COALESCE(nodes.info->>'software_name', ''))"
  end

  def canonical_language(value)
    parts = value.split('-')
    return if parts.empty? || parts.any?(&:blank?)

    parts = parts.each_with_index.map do |part, index|
      if index.zero?
        part.downcase
      elsif part.match?(/\A[a-zA-Z]{4}\z/)
        part.capitalize
      elsif part.match?(/\A(?:[a-zA-Z]{2}|[0-9]{3})\z/)
        part.upcase
      else
        part.downcase
      end
    end
    tag = parts.join('-')
    tag if LANGUAGE_PATTERN.match?(tag)
  end

  def invalid!(name)
    raise Mastodon::InvalidParameterError, "Invalid #{name}"
  end
end
