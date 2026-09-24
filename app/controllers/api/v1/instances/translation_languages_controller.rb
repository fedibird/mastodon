# frozen_string_literal: true

class Api::V1::Instances::TranslationLanguagesController < Api::BaseController
  skip_before_action :require_authenticated_user!, unless: :whitelist_mode?

  before_action :set_languages

  vary_by ''

  def show
    cache_even_if_authenticated!
    render json: @languages
  end

  private

  def set_languages
    if TranslationService.configured?
      @languages = Rails.cache.fetch('translation_service/languages', expires_in: 7.days, race_condition_ttl: 1.hour) { TranslationService.configured.languages }
      @languages['und'] = @languages.delete(nil) if @languages.key?(nil)
    else
      @languages = {}
    end
  end

  # Fedibird has no shared ApiCachingConcern. Keep the existing one-day public cache,
  # and skip it in whitelist mode the same way other public API caches do.
  def cache_even_if_authenticated!
    expires_in(1.day, public: true) unless whitelist_mode?
  end
end
