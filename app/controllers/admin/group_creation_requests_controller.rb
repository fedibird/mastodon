# frozen_string_literal: true

module Admin
  class GroupCreationRequestsController < BaseController
    include GroupAdministrationConcern

    before_action :set_request, only: [:show, :approve, :reject, :icon, :retry_icon]

    def index
      authorize_group_admin!(:group_creation_request, :index?)
      @filter = GroupCreationRequestFilter.new(filter_params)
      @requests = @filter.results.includes(:requester_account, :reviewer_account).page(params[:page]).per(PAGE_SIZE)
      @feature_enabled = GroupCreationRequests::Feature.enabled?
    end

    def show
      authorize_group_admin!(@request, :show?)
      @feature_enabled = GroupCreationRequests::Feature.enabled?
      @audits = group_admin_audits(@request)
    end

    def approve
      authorize_group_admin!(@request, :approve?)
      result = GroupCreationRequests::ApproveService.call(request: @request, reviewer_account: current_account)
      redirect_to admin_group_creation_request_path(result.request), decision_flash(result, :approve)
    end

    def reject
      authorize_group_admin!(@request, :reject?)
      result = GroupCreationRequests::RejectService.call(
        request: @request,
        reviewer_account: current_account,
        decision_note: params[:decision_note].to_s
      )
      redirect_to admin_group_creation_request_path(result.request), decision_flash(result, :reject)
    end

    def icon
      authorize_group_admin!(@request, :icon?)
      send_private_icon
    end

    def retry_icon
      authorize_group_admin!(@request, :retry_icon?)
      code = GroupCreationIcons::RetryHandoff.call(request: @request, actor_account: current_account)
      raise Mastodon::NotPermittedError if code == :not_authorized

      audit_group_action(:retry_icon, @request, code: code)
      redirect_back fallback_location: admin_group_creation_request_path(@request), notice: t("admin.group_creation_requests.retry.#{code}")
    end

    private

    def set_request
      @request = GroupCreationRequest.includes(
        :requester_account,
        :reviewer_account,
        :group_account,
        :initial_owner_account,
        :managed_group,
        decision: :reviewer_account
      ).find(params[:id])
    end

    def filter_params
      params.slice(*GroupCreationRequestFilter::KEYS).permit(*GroupCreationRequestFilter::KEYS)
    end

    def decision_flash(result, action)
      if result.success?
        audit_group_action(action, result.request)
        { notice: t("admin.group_creation_requests.results.#{result.code}") }
      else
        audit_group_action(:fail, result.request, code: result.code)
        { alert: t("admin.group_creation_requests.errors.#{result.code}", default: t('admin.group_creation_requests.errors.conflict')) }
      end
    end

    def send_private_icon
      return not_found unless GroupCreationRequests::Access.preview_allowed?(@request, current_account)
      return not_found unless GroupCreationIcons::Delivery.allowed_mime?(@request.icon_content_type)

      bytes = GroupCreationIcons::Storage.resolve.read(@request.icon_storage_key)
      send_data bytes, type: @request.icon_content_type, disposition: 'inline', filename: GroupCreationIcons::Delivery.filename(@request.icon_content_type)
      GroupCreationIcons::Delivery.headers(@request.icon_content_type).each { |header, value| response.headers[header] = value }
    rescue GroupCreationIcons::NotFound, GroupCreationIcons::Error
      not_found
    end
  end
end
