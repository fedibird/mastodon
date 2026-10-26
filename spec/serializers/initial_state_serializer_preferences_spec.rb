# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InitialStateSerializer do
  def serialize(current_account, visibility: nil)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        InitialStatePresenter.new(current_account: current_account, visibility: visibility),
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  def store_setting(user, var, value)
    record = Setting.unscoped.find_or_initialize_by(thing_type: 'User', thing_id: user.id, var: var)
    record.value = value
    record.save!
    record
  end

  def settings_selects
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      queries << sql if sql.include?('FROM "settings"') && sql.include?('"var" IN') && !sql.include?('SCHEMA')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries.grep(/\ASELECT/i)
  end

  describe 'reader-backed preferences' do
    let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: true)) }

    it 'matches the existing getters for unset values and keeps the same keys' do
      json = serialize(user.account)
      meta = json[:meta]
      compose = json[:compose]

      expect(meta[:reduce_motion]).to eq user.setting_reduce_motion
      expect(meta[:reduce_motion]).to be false
      expect(meta[:new_features_policy]).to eq 'default'
      expect(meta[:new_features_policy]).to eq user.setting_new_features_policy
      expect(meta[:content_font_size]).to eq 15
      expect(meta[:content_font_size]).to be_a(Integer)
      expect(meta[:content_font_size]).to eq user.setting_content_font_size
      expect(meta[:info_font_size]).to eq user.setting_info_font_size
      expect(meta[:translation_preferred_mode]).to eq 'translated'
      expect(meta[:translation_bar_visibility]).to eq 'target'
      expect(meta[:translation_bar_visibility]).to eq user.setting_show_translation_bar
      expect(meta[:enable_local_timeline]).to be false
      expect(meta[:emoji_reaction_fallback_policy]).to eq 'allow'
      expect(compose[:default_privacy]).to eq 'private'
      expect(compose[:default_privacy]).to eq user.setting_default_privacy
      expect(compose[:default_sensitive]).to eq false
      expect(compose[:default_sensitive]).to eq user.setting_default_sensitive
      expect(compose[:default_language]).to eq 'ja'
      expect(compose[:default_language]).to eq user.preferred_posting_language
      expect(meta.keys).to include(
        :reduce_motion, :new_features_policy, :content_font_size, :info_font_size,
        :translation_preferred_mode, :translation_bar_visibility, :translation_private_content_allowed,
        :enable_local_timeline
      )
      expect(compose.keys).to include(:default_privacy, :default_sensitive, :default_language, :default_searchability)
      expect(meta).not_to have_key(:show_translation_bar)
      expect(compose).not_to have_key(:preferred_posting_language)
    end

    it 'uses an unlocked account public default and an explicit visibility override' do
      unlocked = Fabricate(:user, account: Fabricate(:account, locked: false))
      expect(serialize(unlocked.account)[:compose][:default_privacy]).to eq 'public'

      overridden = serialize(unlocked.account, visibility: 'unlisted')
      expect(overridden[:compose][:default_privacy]).to eq 'unlisted'
    end

    it 'keeps a stored empty privacy string and a stored false sensitive flag' do
      store_setting(user, 'default_privacy', '')
      store_setting(user, 'default_sensitive', false)
      json = serialize(user.account)

      expect(json[:compose][:default_privacy]).to eq ''
      expect(json[:compose][:default_privacy]).to eq user.setting_default_privacy
      expect(json[:compose][:default_sensitive]).to be false
      expect(json[:compose][:default_sensitive]).to eq user.setting_default_sensitive
    end

    it 'distinguishes a stored nil language from the derived compose language' do
      store_setting(user, 'default_language', nil)
      json = serialize(user.account)

      expect(user.setting_default_language).to be_nil
      expect(json[:compose][:default_language]).to eq 'ja'
      expect(json[:compose][:default_language]).to eq user.preferred_posting_language
    end

    it 'falls back from an invalid stored language through the user locale and the request locale' do
      store_setting(user, 'default_language', 'invalid')
      expect(serialize(user.account)[:compose][:default_language]).to eq 'ja'

      user.update!(locale: nil)
      I18n.with_locale(:en) do
        expect(serialize(user.account)[:compose][:default_language]).to eq 'en'
        expect(serialize(user.account)[:compose][:default_language]).to eq user.preferred_posting_language
      end
    end

    it 'uses the effective translation bar for legacy booleans and unknown values without rewriting them' do
      store_setting(user, 'new_features_policy', 'conservative')
      record = store_setting(user, 'show_translation_bar', true)
      expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'always'
      expect(record.reload.value).to be true

      store_setting(user, 'show_translation_bar', false)
      expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'never'

      record = store_setting(user, 'show_translation_bar', 'nope')
      expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'never'
      expect(record.reload.value).to eq 'nope'
    end

    it 'normalizes original to translated and keeps numeric font strings' do
      store_setting(user, 'translation_preferred_mode', 'original')
      store_setting(user, 'content_font_size', '18')
      store_setting(user, 'info_font_size', 'invalid')
      json = serialize(user.account)

      expect(json[:meta][:translation_preferred_mode]).to eq 'translated'
      expect(json[:meta][:translation_preferred_mode]).to eq user.setting_translation_preferred_mode
      expect(json[:meta][:content_font_size]).to eq '18'
      expect(json[:meta][:content_font_size]).to be_a(String)
      expect(json[:meta][:content_font_size]).to eq user.setting_content_font_size
      expect(json[:meta][:info_font_size]).to eq 'invalid'
      expect(json[:meta][:info_font_size]).to be_a(String)
    end

    it 'does not build a reader when there is no current account' do
      expect(UserPreferences::Reader).not_to receive(:new)

      json = serialize(nil)

      expect(json[:meta][:reduce_motion]).to eq Setting.reduce_motion
      expect(json[:meta]).not_to have_key(:content_font_size)
      expect(json[:meta]).not_to have_key(:emoji_reaction_fallback_policy)
      expect(json[:meta]).not_to have_key(:translation_bar_visibility)
      expect(json[:compose]).not_to have_key(:default_privacy)
      expect(json[:meta][:enable_local_timeline]).to be_nil
    end

    it 'creates one reader and selects user settings once' do
      expect(UserPreferences::Reader).to receive(:new).once.and_call_original
      cache_from_reader = []
      allow(Rails.cache).to receive(:fetch).and_wrap_original do |method, *args, &block|
        cache_from_reader << args.first if caller.any? { |line| line.include?('user_preferences/reader.rb') }
        method.call(*args, &block)
      end
      allow(Rails.cache).to receive(:write).and_wrap_original do |method, *args, &block|
        cache_from_reader << args.first if caller.any? { |line| line.include?('user_preferences/reader.rb') }
        method.call(*args, &block)
      end

      queries = settings_selects { serialize(user.account) }

      expect(queries.size).to eq 1
      expect(cache_from_reader).to be_empty
    end

    it 'reads the database when the settings cache is stale and does not refresh that cache' do
      user.settings['content_font_size'] = '18'
      expect(user.setting_content_font_size).to eq '18'

      record = Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: 'content_font_size')
      record.update_column(:value, '12'.to_yaml)

      # The getter filled /rev/<revision> before update_column. That write does not delete it.
      expect(user.setting_content_font_size).to eq '18'
      expect(serialize(user.account)[:meta][:content_font_size]).to eq '12'
      expect(user.setting_content_font_size).to eq '18'
    end
  end
end
