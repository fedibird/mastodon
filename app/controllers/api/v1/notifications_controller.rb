# frozen_string_literal: true

class Api::V1::NotificationsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:notifications' }, except: [:clear, :dismiss]
  before_action -> { doorkeeper_authorize! :write, :'write:notifications' }, only: [:clear, :dismiss]
  before_action :require_user!
  after_action :insert_pagination_headers, only: :index

  DEFAULT_NOTIFICATIONS_LIMIT = 15

  def index
    @notifications = load_notifications
    render json: @notifications, each_serializer: REST::NotificationSerializer, relationships: StatusRelationshipsPresenter.new(target_statuses_from_notifications, current_user&.account_id)
  end

  def show
    @notification = current_account.notifications.without_suspended.find(params[:id])
    render json: @notification, serializer: REST::NotificationSerializer
  end

  def clear
    raise Mastodon::NotPermittedError if current_user.setting_disable_clear_all_notifications

    current_account.notifications.delete_all
    render_empty
  end

  def dismiss
    current_account.notifications.find_by!(id: params[:id]).destroy!
    render_empty
  end

  private

  def load_notifications
    notifications = browserable_account_notifications.includes(from_account: :account_stat).to_a_paginated_by_id(
      limit_param(DEFAULT_NOTIFICATIONS_LIMIT),
      params_slice(:max_id, :since_id, :min_id)
    )
    Notification.preload_cache_collection_target_statuses(notifications) do |target_statuses|
      cache_collection(target_statuses, Status)
    end
  end

  def browserable_account_notifications
    current_account.notifications.without_suspended.browserable(exclude_types, from_account)
  end

  def target_statuses_from_notifications
    @notifications.reject { |notification| notification.target_status.nil? }.map(&:target_status)
  end

  def insert_pagination_headers
    set_pagination_headers(next_path, prev_path)
  end

  def next_path
    unless @notifications.empty?
      api_v1_notifications_url pagination_params(max_id: pagination_max_id)
    end
  end

  def prev_path
    unless @notifications.empty?
      api_v1_notifications_url pagination_params(min_id: pagination_since_id)
    end
  end

  def pagination_max_id
    @notifications.last.id
  end

  def pagination_since_id
    @notifications.first.id
  end

  FEDIBIRD_NOTIFICATION_TYPES = %w(emoji_reaction status_reference scheduled_status followed)
  MASTODON_4_0_0_TYPES_AND_LATER = %w(admin.report)
  MASTODON_3_5_0_TYPES_AND_LATER = %w(update admin.sign_up).concat(MASTODON_4_0_0_TYPES_AND_LATER)
  MASTODON_3_3_0_TYPES_AND_LATER = %w(status).concat(MASTODON_3_5_0_TYPES_AND_LATER)
  MASTODON_3_1_0_TYPES_AND_LATER = %w(follow_request).concat(MASTODON_3_3_0_TYPES_AND_LATER)

  EXCLUDE_TYPES_BY_CLIENT = {
    'Mastodon for Android' => FEDIBIRD_NOTIFICATION_TYPES,
    'Tootle for Mastodon'  => FEDIBIRD_NOTIFICATION_TYPES.concat(MASTODON_3_3_0_TYPES_AND_LATER),
    'Tusker'               => FEDIBIRD_NOTIFICATION_TYPES,
    'Mammoth'              => FEDIBIRD_NOTIFICATION_TYPES,
    'Tusky'                => FEDIBIRD_NOTIFICATION_TYPES,
    'Tusky Test'           => FEDIBIRD_NOTIFICATION_TYPES,
    'Yuito'                => FEDIBIRD_NOTIFICATION_TYPES,
    'Milktea'              => FEDIBIRD_NOTIFICATION_TYPES,
    'Pinafore'             => FEDIBIRD_NOTIFICATION_TYPES,
    'Elk'                  => FEDIBIRD_NOTIFICATION_TYPES,
    'trunks.social'        => FEDIBIRD_NOTIFICATION_TYPES,
    'Pachli'               => FEDIBIRD_NOTIFICATION_TYPES,
    'Fedilab'              => FEDIBIRD_NOTIFICATION_TYPES,
  }

  def exclude_types
    val = params.permit(exclude_types: [])[:exclude_types] || []
    val = [val] unless val.is_a?(Enumerable)

    application_name = doorkeeper_token&.application&.name
    val.concat(EXCLUDE_TYPES_BY_CLIENT[application_name] || [])

    val = val << 'emoji_reaction' unless current_user&.setting_enable_reaction
    val = val << 'status_reference' unless current_user&.setting_enable_status_reference
    val.uniq
  end

  def from_account
    params[:account_id]
  end

  def pagination_params(core_params)
    params.slice(:limit, :exclude_types).permit(:limit, exclude_types: []).merge(core_params)
  end
end
