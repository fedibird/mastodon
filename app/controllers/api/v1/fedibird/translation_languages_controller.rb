# frozen_string_literal: true

class Api::V1::Fedibird::TranslationLanguagesController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:statuses' }
  before_action :require_user!

  rescue_from TranslationService::UnexpectedResponseError, with: :service_unavailable

  rescue_from TranslationService::QuotaExceededError do
    render json: { error: I18n.t('translation.errors.quota_exceeded') }, status: 503
  end

  rescue_from TranslationService::TooManyRequestsError do
    render json: { error: I18n.t('translation.errors.too_many_requests') }, status: 503
  end

  # Viewer-specific language map. This is not the shared instance endpoint.
  # A personal provider failure is returned as a provider error and is not
  # replaced with the instance language map.
  def show
    render json: languages_for_viewer
  end

  private

  def languages_for_viewer
    backend = TranslationService.for_user(current_user)
    key = backend.try(:personal_languages_cache_key) || 'translation_service/languages'
    source = Rails.cache.fetch(key, expires_in: 7.days, race_condition_ttl: 1.hour) { backend.languages }
    present_languages(source)
  rescue TranslationService::NotConfiguredError, TranslationService::AmbiguousPersonalProvider
    {}
  end

  # Copy first. The cached provider map keeps a nil auto-detect key.
  # The HTTP response uses und, matching the instance languages endpoint.
  def present_languages(languages)
    presented = languages.dup
    presented['und'] = presented.delete(nil) if presented.key?(nil)
    presented
  end

  def service_unavailable
    render json: { error: 'Service unavailable' }, status: 503
  end
end
