# frozen_string_literal: true

class Api::V1::Statuses::TranslationsController < Api::BaseController
  include Authorization

  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }
  before_action :require_user!
  before_action :set_status
  before_action :set_translation

  rescue_from TranslationService::NotConfiguredError, with: :not_found
  rescue_from TranslationService::UnexpectedResponseError, with: :service_unavailable

  rescue_from TranslationService::QuotaExceededError do
    render json: { error: I18n.t('translation.errors.quota_exceeded') }, status: 503
  end

  rescue_from TranslationService::TooManyRequestsError do
    render json: { error: I18n.t('translation.errors.too_many_requests') }, status: 503
  end

  def create
    render json: @translation, serializer: REST::TranslationSerializer
  end

  private

  def set_status
    @status = Status.find(params[:status_id])
    authorize @status, :show?
  rescue Mastodon::NotPermittedError
    render json: { error: 'Record not found' }, status: 404
  end

  def not_found
    render json: { error: 'Record not found' }, status: 404
  end

  def service_unavailable
    render json: { error: 'Service unavailable' }, status: 503
  end

  def set_translation
    explicit_source = params[:source_language].present?
    explicit_target = params[:target_language].present?

    @translation = if explicit_source || explicit_target
                     TranslateStatusService.new.call(
                       @status,
                       explicit_target ? params[:target_language] : content_locale,
                       source_language: params[:source_language],
                       explicit_source: explicit_source,
                       explicit_target: explicit_target,
                       user: current_user
                     )
                   else
                     TranslateStatusService.new.call(@status, content_locale, user: current_user)
                   end
  end
end
