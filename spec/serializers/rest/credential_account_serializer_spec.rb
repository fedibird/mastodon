# frozen_string_literal: true

require 'rails_helper'

RSpec.describe REST::CredentialAccountSerializer do
  def serialize(record)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        record,
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  def drop_revision_cache(record_user, key)
    revision = UserPreferences::Revision.current(record_user.id)
    Rails.cache.delete(UserPreferences::CacheKey.for_revision(key, record_user, revision))
  end

  def legacy_source(record)
    user = record.user
    JSON.parse({
      privacy: user.setting_default_privacy,
      sensitive: user.setting_default_sensitive,
      language: user.setting_default_language,
      note: record.note,
      fields: record.fields.map(&:to_h),
      follow_requests_count: FollowRequest.where(target_account: record).limit(40).count,
      hide_collections: record.hide_collections,
      discoverable: record.discoverable,
      indexable: record.indexable,
    }.to_json, symbolize_names: true)
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

  describe 'source' do
    let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, username: 'alice', locked: true, note: 'hello')) }
    let(:account) { user.account }

    before do
      account.update!(fields: [{ 'name' => 'Site', 'value' => 'https://example.com' }])
      Fabricate(:follow_request, target_account: account)
    end

    it 'matches the existing getters for the whole source hash when nothing is saved' do
      body = serialize(account)

      expect(body[:source].keys).to eq(legacy_source(account).keys)
      expect(body[:source]).to eq(legacy_source(account))
      expect(body[:source][:privacy]).to eq 'private'
      expect(body[:source][:sensitive]).to be false
      expect(body[:source][:language]).to be_nil
      expect(body[:source][:note]).to eq 'hello'
      expect(body[:source][:fields].first[:name]).to eq 'Site'
      expect(body[:source][:follow_requests_count]).to eq 1
    end

    it 'uses public for an unlocked account when privacy is unset' do
      unlocked = Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: false))

      expect(serialize(unlocked.account)[:source][:privacy]).to eq 'public'
      expect(serialize(unlocked.account)[:source]).to eq(legacy_source(unlocked.account))
    end

    it 'keeps stored privacy values, including nil, an empty string, and direct' do
      [nil, '', 'public', 'private', 'unlisted', 'direct'].each do |visibility|
        user.settings['default_privacy'] = visibility
        drop_revision_cache(user, 'default_privacy')
        body = serialize(account)

        expect(body[:source][:privacy]).to eq(user.setting_default_privacy)
        expect(body[:source]).to eq(legacy_source(account))
      end

      user.settings['default_privacy'] = ''
      expect(serialize(account)[:source][:privacy]).to eq ''

      user.settings['default_privacy'] = nil
      expect(serialize(account)[:source][:privacy]).to eq 'private'
    end

    it 'keeps an unset, true, false, and stored nil sensitive flag' do
      expect(serialize(account)[:source][:sensitive]).to be false

      [true, false, nil].each do |value|
        user.settings['default_sensitive'] = value
        drop_revision_cache(user, 'default_sensitive')
        body = serialize(account)

        expect(body[:source][:sensitive]).to eq value
        expect(body[:source][:sensitive]).to eq user.setting_default_sensitive
        expect(body[:source]).to eq(legacy_source(account))
      end
    end

    it 'keeps the stored language, including nil, a regional tag, and an invalid value' do
      expect(serialize(account)[:source][:language]).to be_nil
      expect(user.preferred_posting_language).to eq 'ja'

      [nil, 'de', 'ja-JP', 'invalid'].each do |language|
        user.settings['default_language'] = language
        drop_revision_cache(user, 'default_language')
        body = serialize(account)

        expect(body[:source][:language]).to eq language
        expect(body[:source][:language]).to eq user.setting_default_language
        expect(body[:source]).to eq(legacy_source(account))
      end

      user.settings['default_language'] = 'ja-JP'
      drop_revision_cache(user, 'default_language')
      expect(serialize(account)[:source][:language]).to eq 'ja-JP'
      expect(user.preferred_posting_language).to eq 'ja'

      user.settings['default_language'] = 'invalid'
      drop_revision_cache(user, 'default_language')
      expect(serialize(account)[:source][:language]).to eq 'invalid'
      expect(user.preferred_posting_language).to eq 'ja'
    end

    it 'follows the in-memory locked flag that the official app mask writes' do
      expect(account.user.account).to equal(account)

      account.locked = false
      body = serialize(account)

      expect(account.attribute_in_database('locked')).to be true
      expect(account.locked?).to be false
      expect(user.setting_default_privacy).to eq 'public'
      expect(body[:source][:privacy]).to eq 'public'
      expect(body[:source]).to eq(legacy_source(account))
      expect(body[:locked]).to be false

      user.settings['default_privacy'] = 'direct'
      drop_revision_cache(user, 'default_privacy')
      body = serialize(account)

      expect(body[:source][:privacy]).to eq 'direct'
      expect(body[:source][:privacy]).to eq user.setting_default_privacy
      expect(body[:locked]).to be false
    end

    it 'creates one reader per serializer instance and selects settings once' do
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

      queries = settings_selects { serialize(account) }

      expect(queries.size).to eq 1
      expect(cache_from_reader).to be_empty
    end

    it 'does not share a reader across serializer instances' do
      expect(UserPreferences::Reader).to receive(:new).twice.and_call_original

      2.times { serialize(account) }
    end

    it 'reads the database for nine-key getters when only the legacy cache is stale' do
      user.settings['default_privacy'] = 'public'
      user.settings['default_sensitive'] = false
      user.settings['default_language'] = 'de'

      {
        'default_privacy' => 'direct',
        'default_sensitive' => true,
        'default_language' => 'ja-JP',
      }.each do |var, value|
        Setting.unscoped.find_by!(thing_type: 'User', thing_id: user.id, var: var).update_column(:value, value.to_yaml)
      end

      expect(Rails.cache.read(Setting.cache_key('default_privacy', user))).to eq 'public'
      expect(Rails.cache.read(Setting.cache_key('default_sensitive', user))).to be false
      expect(Rails.cache.read(Setting.cache_key('default_language', user))).to eq 'de'
      expect(user.setting_default_privacy).to eq 'direct'
      expect(user.setting_default_sensitive).to be true
      expect(user.setting_default_language).to eq 'ja-JP'

      body = serialize(account)

      expect(body[:source][:privacy]).to eq 'direct'
      expect(body[:source][:sensitive]).to be true
      expect(body[:source][:language]).to eq 'ja-JP'
      expect(body[:source][:note]).to eq 'hello'
      expect(body[:source][:follow_requests_count]).to eq 1
      expect(Rails.cache.read(Setting.cache_key('default_privacy', user))).to eq 'public'
      expect(user.setting_default_privacy).to eq 'direct'
      expect(user.setting_default_sensitive).to be true
      expect(user.setting_default_language).to eq 'ja-JP'
    end
  end
end
