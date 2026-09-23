# frozen_string_literal: true

class AccountFilter
  KEYS = %i(
    local
    remote
    by_domain
    active
    pending
    soft_silenced
    hard_silenced
    suspended
    username
    display_name
    email
    ip
    staff
    order
    role_ids
  ).freeze

  attr_reader :params

  def initialize(params)
    @params = params
    set_defaults!
  end

  def results
    scope = Account.includes(:user).reorder(nil)

    params.each do |key, value|
      next if value.blank?

      argument = key.to_s == 'role_ids' ? value : value.to_s.strip
      scope.merge!(scope_for(key, argument))
    end

    scope
  end

  private

  def set_defaults!
    params['local']  = '1' if params['remote'].blank?
    params['active'] = '1' if params['suspended'].blank? && params['soft_silenced'].blank? && params['hard_silenced'].blank? && params['pending'].blank?
    params['order']  = 'recent' if params['order'].blank?
  end

  def scope_for(key, value)
    case key.to_s
    when 'local'
      Account.local.without_instance_actor
    when 'remote'
      Account.remote
    when 'by_domain'
      Account.where(domain: value)
    when 'active'
      Account.without_suspended
    when 'pending'
      accounts_with_users.merge(User.pending)
    when 'disabled'
      accounts_with_users.merge(User.disabled)
    when 'silenced'
      Account.silenced
    when 'soft_silenced'
      Account.soft_silenced
    when 'hard_silenced'
      Account.hard_silenced
    when 'suspended'
      Account.suspended
    when 'username'
      Account.matches_username(value)
    when 'display_name'
      Account.matches_display_name(value)
    when 'email'
      accounts_with_users.merge(User.matches_email(value))
    when 'ip'
      valid_ip?(value) ? accounts_with_users.merge(User.matches_ip(value)) : Account.none
    when 'staff'
      accounts_with_users.merge(User.staff)
    when 'role_ids'
      role_scope(value)
    when 'order'
      order_scope(value)
    else
      raise "Unknown filter: #{key}"
    end
  end

  def order_scope(value)
    case value
    when 'active'
      params['remote'] ? Account.joins(:account_stat).by_recent_status : Account.joins(:user).by_recent_sign_in
    when 'recent'
      Account.recent
    when 'alphabetic'
      Account.alphabetic
    else
      raise "Unknown order: #{value}"
    end
  end

  def accounts_with_users
    Account.joins(:user)
  end

  def role_scope(value)
    accounts_with_users.merge(User.where(role_id: Array(value).map(&:to_s)))
  end

  def valid_ip?(value)
    IPAddr.new(value) && true
  rescue IPAddr::InvalidAddressError
    false
  end
end
