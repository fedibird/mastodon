# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPreferences::WriteContract do
  subject(:contract) { described_class.new }

  def errors_for(updates: {}, resets: [])
    contract.validate!(updates: updates, resets: resets)
    []
  rescue UserPreferences::InvalidInput => error
    error.errors
  end

  it 'accepts only the nine stored keys and leaves the fallback policy unread for writes' do
    expect(described_class::KEYS).to eq(UserPreferences::Reader::STORAGE_KEYS - ['emoji_reaction_fallback_policy'])
    expect(described_class::KEYS.size).to eq 9
    expect(described_class::KEYS).not_to include('preferred_posting_language', 'emoji_reaction_fallback_policy')
    expect(UserPreferences::Schema.get('emoji_reaction_fallback_policy')).to have_attributes(
      write_policy: :read_only,
      derived: false,
      category: :safety
    )
  end

  it 'rejects fallback policy updates because the key is outside the contract, not because write_policy is consulted' do
    found = errors_for(
      updates: { 'emoji_reaction_fallback_policy' => 'deny', 'reduce_motion' => true },
      resets: ['emoji_reaction_fallback_policy']
    )

    expect(found).to include('key' => 'emoji_reaction_fallback_policy', 'code' => 'unknown_key')
    expect(File.read(Rails.root.join('app/lib/user_preferences/writer.rb'))).not_to include('write_policy')
    expect(File.read(Rails.root.join('app/lib/user_preferences/write_contract.rb'))).not_to include('write_policy')
    expect(UserPreferences::Schema).not_to receive(:get)
    contract.validate!(updates: { 'reduce_motion' => true }, resets: [])
  end

  it 'accepts the allowed posting, translation, and appearance values' do
    request = contract.validate!(
      updates: {
        'default_privacy' => 'private',
        'default_sensitive' => false,
        'default_language' => 'zh-CN',
        'show_translation_bar' => 'target',
        'translation_preferred_mode' => 'bilingual',
        'new_features_policy' => 'tester',
        'content_font_size' => 10,
        'info_font_size' => 20,
        'reduce_motion' => true,
      },
      resets: []
    )

    expect(request.updates['default_language']).to eq 'zh-CN'
    expect(request.updates['content_font_size']).to eq 10
  end

  it 'accepts zh-TW, zh-HK, and zh-YUE without stripping the region' do
    %w(zh zh-TW zh-HK zh-YUE ja en de).each do |language|
      request = contract.validate!(updates: { 'default_language' => language }, resets: [])

      expect(request.updates['default_language']).to eq language
    end
  end

  it 'rejects values outside the strict types' do
    cases = {
      'default_privacy' => ['direct', 'limited', '', :public, nil],
      'default_sensitive' => ['false', 0, 1, nil],
      'default_language' => ['ja-JP', 'invalid', '', 'zh-yue', nil],
      'show_translation_bar' => [true, false, 'nope', nil],
      'translation_preferred_mode' => ['original', 'nope', nil],
      'new_features_policy' => ['nope', nil],
      'content_font_size' => ['18', 9, 21, 18.0, nil],
      'info_font_size' => ['15', 0, nil],
      'reduce_motion' => ['true', nil],
    }

    cases.each do |key, values|
      values.each do |value|
        found = errors_for(updates: { key => value })

        expect(found).not_to be_empty, "#{key}=#{value.inspect}"
        expect(found.map { |error| error['key'] }).to include(key)
      end
    end
  end

  it 'rejects preferred language, unknown keys, and symbols' do
    found = errors_for(
      updates: {
        'preferred_posting_language' => 'ja',
        'theme' => 'default',
        :default_sensitive => false,
      },
      resets: ['display_media']
    )

    expect(found.map { |error| error['code'] }).to include('unknown_key', 'invalid_key')
  end

  it 'rejects a key that is both an update and a reset' do
    found = errors_for(updates: { 'default_language' => 'ja' }, resets: ['default_language'])

    expect(found).to include('key' => 'default_language', 'code' => 'duplicate_operation')
  end

  it 'does not mutate the caller collections' do
    updates = { 'default_sensitive' => false }.freeze
    resets = ['default_language'].freeze

    contract.validate!(updates: updates, resets: resets)

    expect(updates).to eq('default_sensitive' => false)
    expect(resets).to eq(['default_language'])
  end

  it 'collects every invalid key before returning' do
    found = errors_for(updates: { 'default_sensitive' => false, 'default_language' => 'ja-JP', 'content_font_size' => '18' })

    expect(found.map { |error| error['key'] }).to eq ['default_language', 'content_font_size']
  end
end
