# frozen_string_literal: true

class LanguageValidator < ActiveModel::EachValidator
  include LanguagesHelper

  def validate_each(record, attribute, value)
    record.errors.add(attribute, :invalid) unless valid?(value)
  end

  private

  def valid?(value)
    if value.nil?
      true
    elsif value.is_a?(Array)
      value.all? { |language| valid_locale?(language) }
    else
      valid_locale?(value)
    end
  end
end
