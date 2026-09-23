# frozen_string_literal: true

class Api::V2::Admin::AccountsController < Api::V1::Admin::AccountsController
  FILTER_PARAMS = %i(
    origin
    status
    permissions
    username
    by_domain
    display_name
    email
    ip
    invited_by
    role_ids
  ).freeze

  PAGINATION_PARAMS = (%i(limit) + FILTER_PARAMS).freeze

  private

  def next_path
    api_v2_admin_accounts_url(pagination_params(max_id: pagination_max_id)) if records_continue?
  end

  def prev_path
    api_v2_admin_accounts_url(pagination_params(min_id: pagination_since_id)) unless @accounts.empty?
  end

  def filtered_accounts
    AccountFilter.new(translated_filter_params).results.without_instance_actor
  end

  def translated_filter_params
    permitted = filter_params.to_h
    translated = translate_origin(permitted).merge(translate_status(permitted))

    %w(username by_domain display_name email ip invited_by).each do |key|
      translated[key] = permitted[key] if permitted[key].present?
    end

    translated['role_ids'] = permitted['role_ids'] if permitted['role_ids'].present?
    translated['role_ids'] = UserRole.that_can(:manage_reports).map(&:id) if permitted['permissions'] == 'staff'

    translated
  end

  def translate_origin(permitted)
    case permitted['origin']
    when 'local'
      { 'local' => '1' }
    when 'remote'
      { 'remote' => '1' }
    when nil, ''
      { 'skip_local_default' => '1' }
    else
      raise Mastodon::InvalidParameterError, "Unknown origin: #{permitted['origin']}"
    end
  end

  def translate_status(permitted)
    case permitted['status']
    when 'active'
      { 'active' => '1' }
    when 'pending'
      { 'pending' => '1' }
    when 'disabled'
      { 'disabled' => '1', 'active' => '1' }
    when 'silenced'
      { 'silenced' => '1', 'skip_active_default' => '1' }
    when 'suspended'
      { 'suspended' => '1' }
    when 'sensitized'
      { 'sensitized' => '1', 'skip_active_default' => '1' }
    when nil, ''
      { 'skip_active_default' => '1' }
    else
      raise Mastodon::InvalidParameterError, "Unknown status: #{permitted['status']}"
    end
  end

  def filter_params
    params.permit(*FILTER_PARAMS, role_ids: [])
  end

  def pagination_params(core_params)
    params.slice(*PAGINATION_PARAMS).permit(*PAGINATION_PARAMS, role_ids: []).merge(core_params)
  end
end
