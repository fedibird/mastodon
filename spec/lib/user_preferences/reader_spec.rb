# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UserPreferences::Reader do
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

  describe 'account' do
    it 'matches the omitted account when the user account is passed explicitly' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      omitted = described_class.new(user).get(:default_privacy)
      explicit = described_class.new(user, account: user.account).get(:default_privacy)

      expect(explicit.state).to eq omitted.state
      expect(explicit.configured).to eq omitted.configured
      expect(explicit.effective).to eq omitted.effective
      expect(explicit.effective).to eq 'private'
      expect(explicit.effective).to eq user.setting_default_privacy
    end

    it 'rejects another account instead of using that account lock state' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      other = Fabricate(:account, locked: false)

      expect { described_class.new(user, account: other) }
        .to raise_error(ArgumentError, 'account must be the account that belongs to the user')
      expect(user.setting_default_privacy).to eq 'private'
      expect(Setting.where(thing_type: 'User', thing_id: user.id, var: 'default_privacy')).to be_empty
    end
  end

  describe 'supported keys' do
    it 'rejects keys outside the P1-1 set without reading settings' do
      user = Fabricate(:user)
      reader = described_class.new(user)

      expect { reader.get(:enable_local_timeline) }.to raise_error(UserPreferences::UnsupportedKey)
      expect(Setting.where(thing_type: 'User', thing_id: user.id, var: 'enable_local_timeline')).to be_empty
    end
  end

  describe 'default_privacy' do
    it 'uses private when nothing is stored and the account is locked' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      reader = described_class.new(user)

      expect { reader.get(:default_privacy) }.not_to change { Setting.where(thing_id: user.id, var: 'default_privacy').count }

      value = reader.get(:default_privacy)
      expect(value.state).to eq :absent
      expect(value.configured).to be_nil
      expect(value.effective).to eq 'private'
      expect(value.public_value).to eq 'private'
      expect(value.effective).to eq user.setting_default_privacy
    end

    it 'uses public when nothing is stored and the account is unlocked' do
      user = Fabricate(:user, account: Fabricate(:account, locked: false))
      value = described_class.new(user).get(:default_privacy)

      expect(value.state).to eq :absent
      expect(value.effective).to eq 'public'
      expect(value.effective).to eq user.setting_default_privacy
    end

    it 'prefers an explicit stored visibility over the locked account' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      store_setting(user, 'default_privacy', 'unlisted')
      value = described_class.new(user).get(:default_privacy)

      expect(value.state).to eq :present
      expect(value.configured).to eq 'unlisted'
      expect(value.effective).to eq 'unlisted'
      expect(value.effective).to eq user.setting_default_privacy
    end

    it 'keeps a stored nil distinct from a missing row and still applies the locked fallback' do
      user = Fabricate(:user, account: Fabricate(:account, locked: true))
      store_setting(user, 'default_privacy', nil)
      value = described_class.new(user).get(:default_privacy)

      expect(value.state).to eq :nil
      expect(value.stored?).to be true
      expect(value.configured).to be_nil
      expect(value.effective).to eq 'private'
    end

    it 'keeps a stored empty string because the existing getter treats it as present' do
      user = Fabricate(:user, account: Fabricate(:account, locked: false))
      store_setting(user, 'default_privacy', '')
      value = described_class.new(user).get(:default_privacy)

      expect(value.state).to eq :present
      expect(value.configured).to eq ''
      expect(value.effective).to eq ''
      expect(value.effective).to eq user.setting_default_privacy
    end
  end

  describe 'default_language and preferred_posting_language' do
    let(:user) { Fabricate(:user, locale: 'ja') }

    it 'keeps the stored language and matches the preferred cascade' do
      store_setting(user, 'default_language', 'de')
      reader = described_class.new(user)
      stored = reader.get(:default_language)
      preferred = reader.get(:preferred_posting_language)

      expect(stored.state).to eq :present
      expect(stored.configured).to eq 'de'
      expect(stored.effective).to eq 'de'
      expect(stored.effective).to eq user.setting_default_language
      expect(preferred.state).to eq :derived
      expect(preferred.configured).to be_nil
      expect(preferred.effective).to eq 'de'
      expect(preferred.public_value).to eq user.preferred_posting_language
    end

    it 'falls back like User#preferred_posting_language when the stored language is invalid' do
      store_setting(user, 'default_language', 'invalid')
      preferred = described_class.new(user).get(:preferred_posting_language)
      raw = described_class.new(user).get(:default_language)

      expect(raw.configured).to eq 'invalid'
      expect(raw.effective).to eq 'invalid'
      expect(preferred.effective).to eq 'ja'
      expect(preferred.effective).to eq user.preferred_posting_language
    end

    it 'falls back to the user locale, then the request locale' do
      user.locale = nil
      user.save!

      I18n.with_locale(:en) do
        preferred = described_class.new(user).get(:preferred_posting_language)
        expect(preferred.effective).to eq 'en'
        expect(preferred.effective).to eq user.preferred_posting_language
      end

      preferred = described_class.new(user, locale: :de).get(:preferred_posting_language)
      expect(preferred.effective).to eq 'de'
    end

    it 'normalizes a regional stored locale only on the derived value' do
      store_setting(user, 'default_language', 'ja-JP')
      reader = described_class.new(user)

      expect(reader.get(:default_language).configured).to eq 'ja-JP'
      expect(reader.get(:preferred_posting_language).effective).to eq 'ja'
      expect(reader.get(:preferred_posting_language).effective).to eq user.preferred_posting_language
    end

    it 'distinguishes a stored nil language from a missing row' do
      store_setting(user, 'default_language', nil)
      value = described_class.new(user).get(:default_language)

      expect(value.state).to eq :nil
      expect(value.configured).to be_nil
      expect(value.effective).to be_nil
    end
  end

  describe 'show_translation_bar' do
    let(:user) { Fabricate(:user) }

    def bar(policy: nil, stored: :missing)
      store_setting(user, 'new_features_policy', policy) unless policy.nil?
      store_setting(user, 'show_translation_bar', stored) unless stored == :missing
      described_class.new(user).get(:show_translation_bar)
    end

    it 'follows the default policy when nothing is stored' do
      value = bar

      expect(value.state).to eq :absent
      expect(value.effective).to eq 'target'
      expect(value.effective).to eq user.setting_show_translation_bar
    end

    it 'follows a stored conservative policy when the bar is unset' do
      value = bar(policy: 'conservative')

      expect(value.effective).to eq 'never'
      expect(value.effective).to eq user.setting_show_translation_bar
    end

    it 'follows a stored tester policy when the bar is unset' do
      value = bar(policy: 'tester')

      expect(value.effective).to eq 'always'
      expect(value.effective).to eq user.setting_show_translation_bar
    end

    it 'follows policy for a stored nil without rewriting the row' do
      store_setting(user, 'new_features_policy', 'tester')
      record = store_setting(user, 'show_translation_bar', nil)
      value = described_class.new(user).get(:show_translation_bar)

      expect(value.state).to eq :nil
      expect(value.effective).to eq 'always'
      expect(record.reload.value).to be_nil
      expect(value.effective).to eq user.setting_show_translation_bar
    end

    it 'keeps a legacy boolean and a current enum as explicit choices' do
      store_setting(user, 'new_features_policy', 'conservative')
      store_setting(user, 'show_translation_bar', true)
      expect(described_class.new(user).get(:show_translation_bar).configured).to be true
      expect(described_class.new(user).get(:show_translation_bar).effective).to eq 'always'

      store_setting(user, 'show_translation_bar', false)
      expect(described_class.new(user).get(:show_translation_bar).effective).to eq 'never'

      store_setting(user, 'show_translation_bar', 'target')
      value = described_class.new(user).get(:show_translation_bar)
      expect(value.configured).to eq 'target'
      expect(value.effective).to eq 'target'
      expect(value.public_value).to eq 'target'
    end

    it 'does not repair an unknown stored visibility' do
      store_setting(user, 'new_features_policy', 'tester')
      record = store_setting(user, 'show_translation_bar', 'nope')
      value = described_class.new(user).get(:show_translation_bar)

      expect(value.configured).to eq 'nope'
      expect(value.effective).to eq 'always'
      expect(value.effective).to eq user.setting_show_translation_bar
      expect(record.reload.value).to eq 'nope'
    end
  end

  describe 'translation_preferred_mode' do
    let(:user) { Fabricate(:user) }

    it 'keeps translated, bilingual, and both' do
      %w(translated bilingual both).each do |mode|
        store_setting(user, 'translation_preferred_mode', mode)
        value = described_class.new(user).get(:translation_preferred_mode)

        expect(value.configured).to eq mode
        expect(value.effective).to eq mode
        # Setting#save! refreshes the legacy cache key only. The previous
        # iteration's getter may already have filled /rev/0.
        Rails.cache.delete(UserPreferences::CacheKey.for_revision('translation_preferred_mode', user, 0))
        expect(value.effective).to eq user.setting_translation_preferred_mode
      end
    end

    it 'uses translated for an unknown mode and does not accept original as a stored default' do
      record = store_setting(user, 'translation_preferred_mode', 'original')
      value = described_class.new(user).get(:translation_preferred_mode)

      expect(value.configured).to eq 'original'
      expect(value.effective).to eq 'translated'
      expect(value.public_value).to eq 'translated'
      expect(value.effective).to eq user.setting_translation_preferred_mode
      expect(record.reload.value).to eq 'original'
    end

    it 'uses the yaml default translated when the row is absent' do
      value = described_class.new(user).get(:translation_preferred_mode)

      expect(value.state).to eq :absent
      expect(value.effective).to eq 'translated'
    end
  end

  describe 'numeric and boolean display settings' do
    let(:user) { Fabricate(:user) }

    it 'uses the integer yaml default when the font size was never stored' do
      value = described_class.new(user).get(:content_font_size)

      expect(value.state).to eq :absent
      expect(value.configured).to be_nil
      expect(value.effective).to eq 15
      expect(value.effective).to be_a(Integer)
      expect(value.public_value).to eq 15
      expect(value.effective).to eq user.setting_content_font_size
    end

    it 'keeps a string saved by the Rails form and exposes an integer public value' do
      store_setting(user, 'info_font_size', '18')
      value = described_class.new(user).get(:info_font_size)

      expect(value.state).to eq :present
      expect(value.configured).to eq '18'
      expect(value.configured).to be_a(String)
      expect(value.effective).to eq '18'
      expect(value.effective).to eq user.setting_info_font_size
      expect(value.public_value).to eq 18
    end

    it 'distinguishes a missing reduce_motion row from a stored false' do
      missing = described_class.new(user).get(:reduce_motion)
      expect(missing.state).to eq :absent
      expect(missing.configured).to be_nil
      expect(missing.effective).to be false
      expect(missing.effective).to eq user.setting_reduce_motion

      store_setting(user, 'reduce_motion', false)
      stored = described_class.new(user).get(:reduce_motion)
      expect(stored.state).to eq :present
      expect(stored.configured).to be false
      expect(stored.effective).to be false
    end
  end

  describe 'migration fixtures' do
    let(:user) { Fabricate(:user, locale: 'ja', account: Fabricate(:account, locked: true)) }

    before do
      store_setting(user, 'default_privacy', 'unlisted')
      store_setting(user, 'default_language', 'ja-JP')
      store_setting(user, 'default_sensitive', false)
      store_setting(user, 'new_features_policy', 'conservative')
      store_setting(user, 'show_translation_bar', true)
      store_setting(user, 'translation_preferred_mode', 'both')
      store_setting(user, 'content_font_size', '16')
    end

    it 'exposes the values a later serializer can compare' do
      values = described_class.new(user).read

      expect(values['default_privacy'].public_value).to eq 'unlisted'
      expect(values['default_sensitive'].public_value).to be false
      expect(values['default_language'].public_value).to eq 'ja-JP'
      expect(values['preferred_posting_language'].public_value).to eq 'ja'
      expect(values['show_translation_bar'].public_value).to eq 'always'
      expect(values['translation_preferred_mode'].public_value).to eq 'both'
      expect(values['new_features_policy'].public_value).to eq 'conservative'
      expect(values['content_font_size'].configured).to eq '16'
      expect(values['content_font_size'].public_value).to eq 16
      expect(values['info_font_size'].state).to eq :absent
      expect(values['info_font_size'].public_value).to eq 15
      expect(values['reduce_motion'].state).to eq :absent
      expect(values['reduce_motion'].public_value).to be false
    end
  end

  describe 'side effects' do
    let(:user) { Fabricate(:user, account: Fabricate(:account, locked: true)) }

    it 'does not write settings, cache, or fan-out work' do
      reader = described_class.new(user)
      expect(Rails.cache).not_to receive(:write)
      expect(Rails.cache).not_to receive(:fetch)
      expect(ActivityPub::UpdateDistributionWorker).not_to receive(:perform_async)

      expect { reader.read }.not_to change { Setting.where(thing_type: 'User', thing_id: user.id).count }
    end

    it 'loads stored rows once' do
      store_setting(user, 'default_privacy', 'private')
      store_setting(user, 'reduce_motion', true)
      reader = described_class.new(user)

      queries = setting_queries { reader.get(:default_privacy) }
      expect(queries.size).to eq 1
      expect(queries.first).to include('thing_id')

      expect(setting_queries { reader.get(:reduce_motion) }).to be_empty
    end
  end
end
