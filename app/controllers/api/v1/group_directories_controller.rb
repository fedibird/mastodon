# frozen_string_literal: true

class Api::V1::GroupDirectoriesController < Api::BaseController
  MAX_QUERY_LENGTH = 100
  MAX_SOFTWARE_LENGTH = 40
  MAX_OFFSET = 10_000
  VALID_ORDERS = %w(active new).freeze
  VALID_SCOPES = %w(all local following).freeze

  before_action :set_accounts

  def show
    render json: @accounts, each_serializer: REST::GroupDirectoryAccountSerializer
  end

  private

  def set_accounts
    @accounts = accounts_scope.offset(directory_offset).limit(limit_param(DEFAULT_ACCOUNTS_LIMIT)).preload(:node)
  end

  def accounts_scope
    # Group is an ActivityPub actor type, not a promise of a conversational
    # community. In particular, PeerTube video channels belong in a separate
    # directory. Keep the existing NodeInfo requirement for remote Groups.
    supported_nodes = Node.has_nodeinfo.where("LOWER(COALESCE(info->>'software_name', '')) <> ?", 'peertube')
    base = Account.discoverable.groups
    scope = base.where(domain: nil).or(base.where(domain: supported_nodes.select(:domain)))

    scope = scope.merge(Account.not_excluded_by_account(current_account)) if current_account
    scope = scope.merge(Account.not_domain_blocked_by_account(current_account)) if current_account

    if (query = directory_param(:q, MAX_QUERY_LENGTH)).present?
      pattern = "%#{Account.sanitize_sql_like(query)}%"
      scope = scope.where(
        'accounts.display_name ILIKE :q OR accounts.username ILIKE :q OR accounts.domain ILIKE :q OR accounts.note ILIKE :q',
        q: pattern
      )
    end

    if (software = directory_param(:software, MAX_SOFTWARE_LENGTH)).present?
      raise Mastodon::InvalidParameterError, 'Invalid software' unless /\A[a-z0-9][a-z0-9_.-]*\z/.match?(software)

      scope = case software
              when 'fedibird'
                scope.where(domain: nil).or(scope.where(domain: Node.software('fedibird').select(:domain)))
              when 'unknown'
                scope.where(domain: Node.has_nodeinfo.where("COALESCE(info->>'software_name', '') = ''").select(:domain))
              else
                scope.where(domain: Node.software(software).select(:domain))
              end
    end

    listing_scope = directory_param(:scope, 16) || 'all'
    raise Mastodon::InvalidParameterError, 'Invalid scope' unless VALID_SCOPES.include?(listing_scope)

    scope = scope.where(domain: nil) if listing_scope == 'local'
    if listing_scope == 'following'
      scope = if current_account
                scope.where(id: Follow.where(account_id: current_account.id).select(:target_account_id))
              else
                scope.none
              end
    end

    order = directory_param(:order, 16) || 'active'
    raise Mastodon::InvalidParameterError, 'Invalid order' unless VALID_ORDERS.include?(order)

    order == 'new' ? scope.order(id: :desc) : scope.merge(Account.by_recent_status)
  end

  def directory_param(name, max_length)
    value = params[name]
    return if value.nil?

    unless value.is_a?(String) && value.length <= max_length
      raise Mastodon::InvalidParameterError, "Invalid #{name}"
    end

    value.strip.presence
  end

  def directory_offset
    value = params[:offset]
    return 0 if value.nil?

    unless value.is_a?(String) && /\A\d{1,5}\z/.match?(value) && value.to_i <= MAX_OFFSET
      raise Mastodon::InvalidParameterError, 'Invalid offset'
    end

    value.to_i
  end
end
