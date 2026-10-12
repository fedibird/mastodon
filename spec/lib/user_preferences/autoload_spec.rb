# frozen_string_literal: true

require 'rails_helper'
require 'open3'

RSpec.describe 'UserPreferences autoload' do
  it 'defines Value in its own file' do
    path = Rails.root.join('app/lib/user_preferences/value.rb').to_s
    expect(Rails.autoloaders.main.cpath_expected_at(path)).to eq 'UserPreferences::Value'
    expect(UserPreferences::Value.instance_method(:stored?).source_location.first).to end_with('user_preferences/value.rb')
  end

  it 'defines UnsupportedKey in its own file' do
    path = Rails.root.join('app/lib/user_preferences/unsupported_key.rb').to_s
    expect(Rails.autoloaders.main.cpath_expected_at(path)).to eq 'UserPreferences::UnsupportedKey'
    expect(UserPreferences::UnsupportedKey).to be < ArgumentError
  end

  it 'references Value and UnsupportedKey before Reader is loaded' do
    stdout, status = Open3.capture2e(
      { 'DISABLE_SPRING' => '1', 'RAILS_ENV' => 'test' },
      RbConfig.ruby,
      '-e',
      <<~RUBY,
        require './config/environment'
        reader = $LOADED_FEATURES.any? { |path| path.end_with?('user_preferences/reader.rb') }
        abort('reader loaded before the constants') if reader

        value = UserPreferences::Value
        error = UserPreferences::UnsupportedKey
        abort('wrong value') unless value.name == 'UserPreferences::Value'
        abort('wrong error') unless error < ArgumentError

        reader = $LOADED_FEATURES.any? { |path| path.end_with?('user_preferences/reader.rb') }
        abort('reader loaded by Value or UnsupportedKey') if reader
      RUBY
      chdir: Rails.root.to_s
    )

    expect(status).to be_success, stdout
  end
end
