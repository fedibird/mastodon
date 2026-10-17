# frozen_string_literal: true

module EmbeddedFilterSettings
  extend ActiveSupport::Concern
  include EmbeddedRailsSettings

  included do
    helper_method :embedded_filter_settings?, :embedded_filter_options
  end

  private

  def embedded_filter_settings?
    embedded_settings?
  end

  def embedded_filter_options
    embedded_settings_options
  end

  def embedded_settings_screen
    'filters'
  end

  def embedded_settings_home
    filters_path(embedded_filter_options)
  end

  def embedded_settings_title
    I18n.t('filters.index.title')
  end
end
