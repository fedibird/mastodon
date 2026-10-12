# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::PreferencesSerializer do
  subject(:json) do
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        account,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  let(:user) { Fabricate(:user) }
  let(:account) { user.account }

  it 'returns a valid configured posting language' do
    user.settings['default_language'] = 'de'

    expect(json[:'posting:default:language']).to eq 'de'
  end

  it 'falls back posting language to the user locale when the default is invalid' do
    user.locale = 'ja'
    user.settings['default_language'] = 'invalid'

    expect(json[:'posting:default:language']).to eq 'ja'
  end

  it 'returns false by default' do
    expect(json).to include('reading:autoplay:gifs': false)
  end

  it 'returns true when all autoplay settings are enabled' do
    enable_autoplay!

    expect(json[:'reading:autoplay:gifs']).to be true
  end

  it 'returns false when any autoplay setting is disabled' do
    enable_autoplay!
    user.settings['auto_play_media'] = false

    expect(json[:'reading:autoplay:gifs']).to be false
  end

  describe 'reader-backed posting preferences' do
    def serialize(record = account)
      JSON.parse(
        ActiveModelSerializers::SerializableResource.new(
          record,
          serializer: described_class
        ).to_json,
        symbolize_names: true
      )
    end

    def legacy_preferences(record_user)
      {
        'posting:default:visibility': record_user.setting_default_privacy,
        'posting:default:sensitive': record_user.setting_default_sensitive,
        'posting:default:language': record_user.preferred_posting_language,
        'reading:expand:media': record_user.setting_display_media,
        'reading:expand:spoilers': record_user.setting_expand_spoilers,
        'reading:autoplay:gifs': record_user.setting_auto_play_avatar &&
          record_user.setting_auto_play_emoji &&
          record_user.setting_auto_play_header &&
          record_user.setting_auto_play_media,
      }
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

    it 'matches the existing getters for every key when the cache is consistent' do
      locked = Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: true))
      unlocked = Fabricate(:user, locale: 'en', account: Fabricate(:account, locked: false))

      [locked, unlocked].each do |record_user|
        expected = legacy_preferences(record_user)
        body = serialize(record_user.account)

        expect(body.keys).to eq(expected.keys)
        expect(body).to eq(expected)
      end

      expect(serialize(locked.account)[:'posting:default:visibility']).to eq 'private'
      expect(serialize(unlocked.account)[:'posting:default:visibility']).to eq 'public'
      expect(serialize(locked.account)[:'posting:default:sensitive']).to be false
      expect(serialize(unlocked.account)[:'posting:default:language']).to eq 'en'
    end

    it 'keeps stored visibilities, including direct and an empty string' do
      locked = Fabricate(:user, account: Fabricate(:account, locked: true))

      %w(public unlisted direct).each do |visibility|
        locked.settings['default_privacy'] = visibility
        body = serialize(locked.account)

        expect(body[:'posting:default:visibility']).to eq visibility
        expect(body).to eq(legacy_preferences(locked))
      end

      locked.settings['default_privacy'] = ''
      body = serialize(locked.account)

      expect(body[:'posting:default:visibility']).to eq ''
      expect(body[:'posting:default:visibility']).to eq locked.setting_default_privacy
      expect(body).to eq(legacy_preferences(locked))
    end

    it 'keeps an unset, false, true, and stored nil sensitive flag' do
      record_user = Fabricate(:user, locale: 'ja')

      expect(serialize(record_user.account)[:'posting:default:sensitive']).to be false

      [false, true, nil].each do |value|
        record_user.settings['default_sensitive'] = value
        body = serialize(record_user.account)

        expect(body[:'posting:default:sensitive']).to eq value
        expect(body[:'posting:default:sensitive']).to eq record_user.setting_default_sensitive
        expect(body).to eq(legacy_preferences(record_user))
      end
    end

    it 'derives posting language from the cascade and does not return the raw stored language' do
      record_user = Fabricate(:user, locale: 'ja')

      expect(serialize(record_user.account)[:'posting:default:language']).to eq 'ja'
      expect(serialize(record_user.account)).to eq(legacy_preferences(record_user))

      record_user.settings['default_language'] = nil
      expect(record_user.setting_default_language).to be_nil
      expect(serialize(record_user.account)[:'posting:default:language']).to eq 'ja'

      record_user.settings['default_language'] = 'de'
      expect(serialize(record_user.account)[:'posting:default:language']).to eq 'de'

      record_user.settings['default_language'] = 'invalid'
      expect(serialize(record_user.account)[:'posting:default:language']).to eq 'ja'
      expect(serialize(record_user.account)[:'posting:default:language']).not_to eq record_user.setting_default_language

      record_user.update!(locale: nil)
      I18n.with_locale(:en) do
        body = serialize(record_user.account)
        expect(body[:'posting:default:language']).to eq 'en'
        expect(body[:'posting:default:language']).to eq record_user.preferred_posting_language
        expect(body).to eq(legacy_preferences(record_user))
      end
    end

    it 'normalizes a regional language tag on the posting language only' do
      record_user = Fabricate(:user, locale: 'en')
      record_user.settings['default_language'] = 'ja-JP'
      body = serialize(record_user.account)

      expect(record_user.setting_default_language).to eq 'ja-JP'
      expect(body[:'posting:default:language']).to eq 'ja'
      expect(body[:'posting:default:language']).to eq record_user.preferred_posting_language
      expect(body).to eq(legacy_preferences(record_user))
    end

    it 'creates one reader per serializer instance and selects settings once' do
      record_user = Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: true))
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

      queries = settings_selects { serialize(record_user.account) }

      expect(queries.size).to eq 1
      expect(cache_from_reader).to be_empty
    end

    it 'does not share a reader across serializer instances' do
      expect(UserPreferences::Reader).to receive(:new).twice.and_call_original

      2.times { serialize(account) }
    end

    it 'follows the database for posting keys and the stale cache for reading keys' do
      record_user = Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: false))
      record_user.settings['default_sensitive'] = false
      record_user.settings['expand_spoilers'] = false
      record_user.settings['default_privacy'] = 'public'

      %w(default_sensitive expand_spoilers).each do |var|
        Setting.unscoped.find_by!(thing_type: 'User', thing_id: record_user.id, var: var).update_column(:value, true.to_yaml)
      end
      Setting.unscoped.find_by!(thing_type: 'User', thing_id: record_user.id, var: 'default_privacy').update_column(:value, 'direct'.to_yaml)

      expect(record_user.setting_default_sensitive).to be false
      expect(record_user.setting_expand_spoilers).to be false
      expect(record_user.setting_default_privacy).to eq 'public'

      body = serialize(record_user.account)

      expect(body[:'posting:default:sensitive']).to be true
      expect(body[:'posting:default:visibility']).to eq 'direct'
      expect(body[:'reading:expand:spoilers']).to be false
      expect(record_user.setting_default_sensitive).to be false
      expect(record_user.setting_expand_spoilers).to be false
      expect(record_user.setting_default_privacy).to eq 'public'
    end
  end

  def enable_autoplay!
    user.settings['auto_play_avatar'] = true
    user.settings['auto_play_emoji'] = true
    user.settings['auto_play_header'] = true
    user.settings['auto_play_media'] = true
  end
end
