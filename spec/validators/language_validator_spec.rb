# frozen_string_literal: true

require 'rails_helper'

RSpec.describe LanguageValidator, type: :validator do
  subject do
    Class.new do
      include ActiveModel::Validations
      attr_accessor :languages
      validates :languages, language: true
    end.new
  end

  it 'accepts nil' do
    subject.languages = nil
    expect(subject).to be_valid
  end

  it 'accepts an empty array' do
    subject.languages = []
    expect(subject).to be_valid
  end

  it 'accepts a supported locale' do
    subject.languages = ['en']
    expect(subject).to be_valid
  end

  it 'accepts multiple supported locales' do
    subject.languages = %w(en ja)
    expect(subject).to be_valid
  end

  it 'rejects an unsupported locale' do
    subject.languages = ['zz-invalid']
    expect(subject).to_not be_valid
    expect(subject).to model_have_error_on_field(:languages)
  end
end
