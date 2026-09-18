# frozen_string_literal: true

class PrivacyPolicy < ActiveModelSerializers::Model
  DEFAULT_UPDATED_AT = DateTime.new(2018, 3, 7).freeze

  attributes :updated_at, :text

  def self.current
    custom = Setting.find_by(var: 'site_terms')

    if custom&.value.present?
      new(text: custom.value, updated_at: custom.updated_at)
    else
      new(text: default_text, updated_at: DEFAULT_UPDATED_AT)
    end
  end

  def self.default_text
    I18n.t('terms.body_html', locale: I18n.default_locale)
  end
end
