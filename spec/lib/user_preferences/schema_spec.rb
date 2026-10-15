# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPreferences::Schema do
  def store_setting(user, var, value)
    record = Setting.unscoped.find_or_initialize_by(thing_type: 'User', thing_id: user.id, var: var)
    record.value = value
    record.save!
    record
  end

  def setting_queries
    queries = []
    callback = lambda do |_name, _start, _finish, _id, payload|
      sql = payload[:sql]
      queries << sql if sql.include?('settings') && !sql.include?('SCHEMA')
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    queries
  end

  describe 'registry' do
    it 'defines the same keys as the reader' do
      expect(described_class.validate_structure!).to be true
      expect(described_class.keys).to eq UserPreferences::Reader::KEYS
      expect(described_class.all.map(&:key)).to eq described_class.keys
      expect(described_class.all.select(&:derived).map(&:key)).to eq UserPreferences::Reader::DERIVED_KEYS
      expect(described_class.all.reject(&:derived).map(&:storage_key)).to eq UserPreferences::Reader::STORAGE_KEYS
    end

    it 'returns every definition without a user or a settings query' do
      expect(setting_queries { described_class.all }).to be_empty
      expect(described_class.all.map(&:key)).to contain_exactly(
        'default_privacy',
        'default_sensitive',
        'default_language',
        'preferred_posting_language',
        'show_translation_bar',
        'translation_preferred_mode',
        'new_features_policy',
        'content_font_size',
        'info_font_size',
        'reduce_motion'
      )
    end

    it 'marks posting and translation keys for reinitialize and appearance keys for live application' do
      reinitialize = %w(
        default_privacy
        default_sensitive
        default_language
        preferred_posting_language
        show_translation_bar
        translation_preferred_mode
        new_features_policy
      )
      live_keys = %w(content_font_size info_font_size reduce_motion)

      expect(reinitialize.map { |key| described_class.get(key).apply_hint }).to all(eq(:reinitialize))
      expect(live_keys.map { |key| described_class.get(key).apply_hint }).to all(eq(:live))
      expect(described_class.get(:show_translation_bar).dependencies).to eq ['new_features_policy']
    end

    it 'rejects a key the reader does not support' do
      expect { described_class.get(:enable_local_timeline) }.to raise_error(UserPreferences::UnsupportedKey)
    end

    it 'does not expose definitions for mutation' do
      expect { described_class.keys << 'extra' }.to raise_error(FrozenError)
      expect { described_class.get(:default_privacy).allowed_values << 'direct' }.to raise_error(FrozenError)
      expect { described_class.get(:content_font_size).ui_range[:min] = 1 }.to raise_error(FrozenError)
      expect(described_class.keys).to eq UserPreferences::Reader::KEYS
    end
  end

  describe 'default_privacy' do
    subject(:definition) { described_class.get(:default_privacy) }

    it 'uses the form choices and records the locked-account dependency' do
      expect(definition.allowed_values).to eq Status.selectable_visibilities
      expect(definition.allowed_values).not_to include('direct', 'limited')
      expect(definition.choice?('public')).to be true
      expect(definition.choice?('direct')).to be false
      expect(definition.dependencies).to eq ['account.locked']
      expect(definition.default_source).to include('account.locked')
    end

    it 'accepts a stored visibility that the form does not offer' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      store_setting(user, 'default_privacy', 'direct')
      value = UserPreferences::Reader.new(user).get(:default_privacy)
      result = definition.check(value)

      expect(definition.choice?('direct')).to be false
      expect(result.public_match?).to be true
      expect(value.configured).to eq 'direct'
      expect(value.effective).to eq 'direct'
    end
  end

  describe 'preferred_posting_language' do
    subject(:definition) { described_class.get(:preferred_posting_language) }

    it 'is a read-only derived value with locale dependencies' do
      expect(definition.derived).to be true
      expect(definition.storage_key).to be_nil
      expect(definition.configured_type).to be_nil
      expect(definition.write_policy).to eq :read_only
      expect(definition.dependencies).to eq ['default_language', 'user.locale', 'request_locale']
      expect(definition.allowed_values).to be_nil
    end

    it 'matches the reader cascade without a stored row of its own' do
      user = Fabricate(:user, locale: 'ja')
      store_setting(user, 'default_language', 'invalid')
      value = UserPreferences::Reader.new(user).get(:preferred_posting_language)

      expect(value.state).to eq :derived
      expect(value.effective).to eq 'ja'
      expect(definition.check(value).match?).to be true
    end
  end

  describe 'show_translation_bar' do
    subject(:definition) { described_class.get(:show_translation_bar) }

    it 'lists the current choices and keeps legacy nil and boolean formats' do
      expect(definition.allowed_values).to eq %w(always target never)
      expect(definition.legacy_formats).to eq [nil, true, false]
      expect(definition.dependencies).to eq ['new_features_policy']
      expect(definition.configured_type).to include(:nil, :boolean, :string)
    end

    it 'does not treat a legacy boolean or an unknown string as a repair' do
      user = Fabricate(:user)
      store_setting(user, 'new_features_policy', 'tester')
      store_setting(user, 'show_translation_bar', true)
      legacy = UserPreferences::Reader.new(user).get(:show_translation_bar)
      expect(legacy.configured).to be true
      expect(legacy.public_value).to eq 'always'
      expect(definition.check(legacy).public_match?).to be true

      store_setting(user, 'show_translation_bar', 'nope')
      unknown = UserPreferences::Reader.new(user).get(:show_translation_bar)
      expect(unknown.configured).to eq 'nope'
      expect(unknown.public_value).to eq 'always'
      expect(definition.choice?('nope')).to be false
      expect(definition.check(unknown).match?).to be true
    end
  end

  describe 'translation_preferred_mode' do
    subject(:definition) { described_class.get(:translation_preferred_mode) }

    it 'does not offer original as a stored default' do
      expect(definition.allowed_values).to eq %w(translated bilingual both)
      expect(definition.allowed_values).not_to include('original')
      expect(definition.choice?('original')).to be false
    end
  end

  describe 'font size types' do
    subject(:definition) { described_class.get(:content_font_size) }

    it 'keeps the form range separate from any server storage constraint' do
      expect(definition.ui_range).to eq(min: 10, max: 20, step: nil)
      expect(definition.storage_constraint).to be_nil
      expect(definition.public_type).to eq [:integer]
      expect(definition.effective_type).to include(:integer, :string)
    end

    it 'accepts a numeric string the reader exposes as an integer' do
      user = Fabricate(:user)
      store_setting(user, 'content_font_size', '18')
      value = UserPreferences::Reader.new(user).get(:content_font_size)
      result = definition.check(value)

      expect(value.configured).to eq '18'
      expect(value.public_value).to eq 18
      expect(result.match?).to be true
    end

    it 'reports a non-numeric string without rewriting the reader value' do
      user = Fabricate(:user)
      store_setting(user, 'content_font_size', 'invalid')
      value = UserPreferences::Reader.new(user).get(:content_font_size)
      result = definition.check(value)

      expect(value.public_value).to eq 'invalid'
      expect(result.public_match?).to be false
      expect(result.effective_match?).to be true
      expect(result.configured_match?).to be true
      expect(result.mismatches).to contain_exactly(
        field: :public_value,
        expected: [:integer],
        actual: :string,
        value: 'invalid'
      )
    end

    it 'still type-checks an integer outside the form range' do
      value = UserPreferences::Value.new(
        key: 'content_font_size',
        state: :present,
        configured: '99',
        effective: '99',
        public_value: 99
      )

      expect(definition.ui_range[:max]).to eq 20
      expect(definition.check(value).public_match?).to be true
    end
  end

  describe 'info_font_size' do
    it 'uses the same form range and integer public type' do
      definition = described_class.get(:info_font_size)

      expect(definition.ui_range).to eq(min: 10, max: 20, step: nil)
      expect(definition.public_type).to eq [:integer]
      expect(definition.category).to eq :appearance
    end
  end
end
