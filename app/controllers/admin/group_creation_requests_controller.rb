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
      redirect_to admin_group_creation_request_path(result.request), decision_flash(result)
    end

    def reject
      authorize_group_admin!(@request, :reject?)
      result = GroupCreationRequests::RejectService.call(
        request: @request,
        reviewer_account: current_account,
        decision_note: params[:decision_note].to_s
      )
      redirect_to admin_group_creation_request_path(result.request), decision_flash(result)
    end

    def icon
      authorize_group_admin!(@request, :icon?)
      send_private_icon
    end

    def retry_icon
      authorize_group_admin!(@request, :retry_icon?)
      code = GroupCreationIcons::RetryHandoff.call(request: @request, actor_account: current_account)
      raise Mastodon::NotPermittedError if code == :not_authorized

      GroupAdministration::Audit.record!(
        account: current_account,
        action: :retry_icon,
        target: @request,
        changes: { 'code' => code.to_s }
      )
      redirect_back fallback_location: admin_group_creation_request_path(@request), notice: t("admin.group_creation_requests.retry.#{code}")
    rescue GroupAdministration::Audit::Error
      redirect_back fallback_location: admin_group_creation_request_path(@request), alert: t('admin.group_administration.audit_failed')
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

    # A successful decision is already audited by GroupCreationDecision inside
    # the P2-A transaction. This screen does not write a second success row.
    # A refused decision has no decision row, so the failure code is logged
    # here. The note itself is not stored in that log.
    def decision_flash(result)
      if result.success?
        return { alert: t('admin.group_administration.audit_failed') } unless decision_recorded?(result)

        { notice: t("admin.group_creation_requests.results.#{result.code}") }
      else
        GroupAdministration::Audit.record!(
          account: current_account,
          action: :fail,
          target: result.request,
          changes: { 'code' => result.code.to_s }
        )
        { alert: t("admin.group_creation_requests.errors.#{result.code}", default: t('admin.group_creation_requests.errors.conflict')) }
      end
    rescue GroupAdministration::Audit::Error
      { alert: t('admin.group_administration.audit_failed') }
    end

    def decision_recorded?(result)
      decision = result.request.reload.decision
      decision&.persisted? && decision.action == result.code.to_s
    end

    def send_private_icon
      return not_found unless GroupCreationRequests::Access.preview_allowed?(@request, current_account)
      return not_found unless GroupCreationIcons::Delivery.allowed_mime?(@request.icon_content_type)

      storage = GroupCreationIcons::Storage.resolve
      if storage.respond_to?(:byte_size)
        size = storage.byte_size(@request.icon_storage_key)
        return not_found if size.nil? || size >= GroupCreationIcons::MAX_BYTES || size != @request.icon_byte_size
      end

      bytes = storage.read(@request.icon_storage_key)
      return not_found if bytes.nil? || bytes.bytesize >= GroupCreationIcons::MAX_BYTES || bytes.bytesize != @request.icon_byte_size

      send_data bytes, type: @request.icon_content_type, disposition: 'inline', filename: GroupCreationIcons::Delivery.filename(@request.icon_content_type)
      GroupCreationIcons::Delivery.headers(@request.icon_content_type).each { |header, value| response.headers[header] = value }
    rescue GroupCreationIcons::NotFound, GroupCreationIcons::Error
      not_found
    rescue StandardError => e
      Rails.logger.error("Group creation icon preview failed request_id=#{@request.id} error=#{e.class}")
      service_unavailable
    end
  end
end
