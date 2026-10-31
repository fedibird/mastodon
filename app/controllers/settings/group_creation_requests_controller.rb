# frozen_string_literal: true

class Settings::GroupCreationRequestsController < Settings::BaseController
  before_action :require_group_creation_applicant!
  before_action :set_request, only: [:show, :cancel, :icon]
  prepend_before_action :require_group_creation_feature!

  def index
    @requests = current_account.group_creation_requests.order(requested_at: :desc, id: :desc)
  end

  def new
    @previous_request = find_reapply_source
    @request = blank_request(@previous_request)
  end

  def confirm
    @previous_request = find_reapply_source
    @request = blank_request(@previous_request)
    @request.valid?
    inspection = inspect_icon(@request, request_params[:icon])
    if @request.errors.any?
      render :new
      return
    end

    GroupCreationIcons::DraftStore.write!(session: session, request: @request, inspection: inspection)
    redirect_to review_settings_group_creation_requests_path
  rescue GroupCreationIcons::ConfigurationError
    @request.errors.add(:base, I18n.t('group_creation_requests.icon_errors.storage_unavailable'))
    render :new, status: :unprocessable_entity
  end

  def review
    @draft = current_draft
    if @draft.nil?
      redirect_to new_settings_group_creation_request_path, alert: I18n.t('group_creation_requests.expired')
      return
    end

    @request = preview_from_draft(@draft)
  end

  def create
    draft = current_draft
    if draft.nil?
      redirect_to new_settings_group_creation_request_path, alert: I18n.t('group_creation_requests.expired')
      return
    end

    unless ActiveModel::Type::Boolean.new.cast(params[:confirmed])
      @draft = draft
      @request = preview_from_draft(draft)
      @request.errors.add(:base, I18n.t('group_creation_requests.errors.confirm_required'))
      render :review
      return
    end

    result = GroupCreationRequests::Commit.call(requester_account: current_account, draft: draft)
    finish_create(result)
  end

  def show; end

  def cancel
    @request.lock_version = params[:lock_version].to_i
    @request.record_cancellation!
    redirect_to settings_group_creation_request_path(@request), notice: I18n.t('group_creation_requests.cancelled')
  rescue ActiveRecord::StaleObjectError
    redirect_to settings_group_creation_request_path(@request), alert: I18n.t('group_creation_requests.stale')
  rescue ActiveRecord::RecordInvalid
    redirect_to settings_group_creation_request_path(@request), alert: I18n.t('group_creation_requests.cancel_failed')
  end

  def icon
    return not_found unless GroupCreationRequests::Access.preview_allowed?(@request, current_account)

    send_stored_icon(@request.icon_storage_key, @request.icon_content_type)
  end

  def draft_icon
    draft = current_draft
    return not_found if draft.nil? || draft['icon_storage_key'].blank?

    send_stored_icon(draft['icon_storage_key'], draft['icon_content_type'])
  end

  def destroy_draft
    GroupCreationIcons::DraftStore.discard!(session)
    redirect_to settings_group_creation_requests_path, notice: I18n.t('group_creation_requests.draft_discarded')
  end

  private

  def current_draft
    GroupCreationIcons::DraftStore.read(session, account: current_account)
  end

  def require_group_creation_feature!
    not_found unless GroupCreationRequests::Feature.enabled?
  end

  def require_group_creation_applicant!
    forbidden unless GroupManagement.local_functional_person?(current_account)
  end

  def set_request
    @request = current_account.group_creation_requests.find(params[:id])
  end

  def find_reapply_source
    raw = params[:previous_request_id].presence
    return if raw.blank?

    record = current_account.group_creation_requests.find(raw)
    raise ActiveRecord::RecordNotFound unless record.rejected? || record.cancelled?
    raise ActiveRecord::RecordNotFound if record.successor_request.present?

    record
  end

  def request_params
    params.require(:group_creation_request).permit(:username, :display_name, :note, :icon)
  end

  def blank_request(previous)
    current_account.group_creation_requests.new(
      username: request_attribute(:username) || previous&.username,
      display_name: request_attribute(:display_name) || previous&.display_name,
      note: request_attribute(:note) || previous&.note,
      previous_request: previous
    )
  end

  def request_attribute(name)
    return unless params[:group_creation_request].is_a?(ActionController::Parameters)

    params[:group_creation_request][name]
  end

  def preview_from_draft(draft)
    current_account.group_creation_requests.new(
      username: draft['username'],
      display_name: draft['display_name'],
      note: draft['note']
    )
  end

  def inspect_icon(record, icon)
    return if icon.blank?

    inspection = GroupCreationIcons::Inspector.call(icon)
    record.errors.add(:base, I18n.t("group_creation_requests.icon_errors.#{inspection.error}")) unless inspection.ok?
    unless GroupCreationIcons::Storage.available?
      record.errors.add(:base, I18n.t('group_creation_requests.icon_errors.storage_unavailable'))
      return
    end

    inspection if inspection.ok?
  end

  def finish_create(result)
    case result.status
    when :created
      GroupCreationIcons::DraftStore.clear!(session)
      redirect_to settings_group_creation_request_path(result.request), notice: I18n.t('group_creation_requests.created')
    when :duplicate
      GroupCreationIcons::DraftStore.clear!(session)
      redirect_to settings_group_creation_request_path(result.request), notice: I18n.t('group_creation_requests.duplicate')
    else
      @draft = current_draft
      @request = result.request
      render :review
    end
  end

  def send_stored_icon(key, mime)
    return not_found unless GroupCreationIcons::Delivery.allowed_mime?(mime)

    bytes = GroupCreationIcons::Storage.resolve.read(key)
    send_data bytes, type: mime, disposition: 'inline', filename: GroupCreationIcons::Delivery.filename(mime)
    GroupCreationIcons::Delivery.headers(mime).each { |header, value| response.headers[header] = value }
  rescue GroupCreationIcons::NotFound, GroupCreationIcons::Error
    not_found
  end
end
