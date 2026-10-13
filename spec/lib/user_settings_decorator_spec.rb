# frozen_string_literal: true

require 'rails_helper'

describe UserSettingsDecorator do
  describe 'update' do
    let(:user) { Fabricate(:user) }
    let(:settings) { described_class.new(user) }

    it 'updates the user settings value for email notifications' do
      values = { 'notification_emails' => { 'follow' => '1' } }

      settings.update(values)
      expect(user.settings['notification_emails']['follow']).to eq true
    end

    it 'updates the user settings value for interactions' do
      values = { 'interactions' => { 'must_be_follower' => '0' } }

      settings.update(values)
      expect(user.settings['interactions']['must_be_follower']).to eq false
    end

    it 'refuses a privacy write before saving when no legacy writer is attached' do
      expect do
        settings.update('setting_default_privacy' => 'public')
      end.to raise_error(UserSettingsDecorator::MissingLegacyWriter)

      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'default_privacy')).not_to exist
    end

    it 'refuses a sensitive write before saving when no legacy writer is attached' do
      expect do
        settings.update('setting_default_sensitive' => '1')
      end.to raise_error(UserSettingsDecorator::MissingLegacyWriter)

      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'default_sensitive')).not_to exist
    end

    it 'stores the composer posting style selector as a display preference' do
      expect(user.setting_show_composer_posting_style_selector).to be true

      settings.update('setting_show_composer_posting_style_selector' => '0')

      expect(user.settings['show_composer_posting_style_selector']).to be false
      expect(user.setting_show_composer_posting_style_selector).to be false
    end

    it 'updates the user settings value for follow modal' do
      values = { 'setting_follow_modal' => '0' }

      settings.update(values)
      expect(user.settings['follow_modal']).to eq false
    end

    it 'updates the user settings value for unfollow modal' do
      values = { 'setting_unfollow_modal' => '0' }

      settings.update(values)
      expect(user.settings['unfollow_modal']).to eq false
    end

    it 'updates the user settings value for subscribe modal' do
      values = { 'setting_subscribe_modal' => '0' }

      settings.update(values)
      expect(user.settings['subscribe_modal']).to eq false
    end

    it 'updates the user settings value for unsubscribe modal' do
      values = { 'setting_unsubscribe_modal' => '0' }

      settings.update(values)
      expect(user.settings['unsubscribe_modal']).to eq false
    end

    it 'updates the user settings value for follow tag modal' do
      values = { 'setting_follow_tag_modal' => '0' }

      settings.update(values)
      expect(user.settings['follow_tag_modal']).to eq false
    end

    it 'updates the user settings value for unfollow tag modal' do
      values = { 'setting_unfollow_tag_modal' => '0' }

      settings.update(values)
      expect(user.settings['unfollow_tag_modal']).to eq false
    end

    it 'updates the user settings value for unsubscribe modal' do
      values = { 'setting_unsubscribe_modal' => '0' }

      settings.update(values)
      expect(user.settings['unsubscribe_modal']).to eq false
    end

    it 'updates the user settings value for boost modal' do
      values = { 'setting_boost_modal' => '1' }

      settings.update(values)
      expect(user.settings['boost_modal']).to eq true
    end

    it 'updates the user settings value for delete toot modal' do
      values = { 'setting_delete_modal' => '0' }

      settings.update(values)
      expect(user.settings['delete_modal']).to eq false
    end

    it 'updates the user settings value for avatar auto play' do
      values = { 'setting_auto_play_avatar' => '0' }

      settings.update(values)
      expect(user.settings['auto_play_avatar']).to eq false
    end

    it 'updates the user settings value for header auto play' do
      values = { 'setting_auto_play_header' => '0' }

      settings.update(values)
      expect(user.settings['auto_play_header']).to eq false
    end

    it 'updates the user settings value for emoji auto play' do
      values = { 'setting_auto_play_emoji' => '0' }

      settings.update(values)
      expect(user.settings['auto_play_emoji']).to eq false
    end

    it 'updates the user settings value for media auto play' do
      values = { 'setting_auto_play_media' => '0' }

      settings.update(values)
      expect(user.settings['auto_play_media']).to eq false
    end

    it 'updates the user settings value for system font in UI' do
      values = { 'setting_system_font_ui' => '0' }

      settings.update(values)
      expect(user.settings['system_font_ui']).to eq false
    end

    it 'refuses a nine-key write before nested or high-risk keys are saved' do
      expect do
        settings.update(
          'notification_emails' => { 'follow' => '1' },
          'setting_disable_post' => '1',
          'setting_default_privacy' => 'direct'
        )
      end.to raise_error(UserSettingsDecorator::MissingLegacyWriter)

      rows = Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: %w(notification_emails disable_post default_privacy))
      expect(rows).to be_empty
    end

    it 'skips a nil nine-key and still saves another setting without a legacy writer' do
      user.settings['default_privacy'] = 'direct'

      expect(settings.update('setting_default_privacy' => nil, 'setting_disable_post' => '1')).to be false

      expect(user.settings['default_privacy']).to eq 'direct'
      expect(user.settings['disable_post']).to be true
    end

    it 'reports a profile change from key presence' do
      expect(settings.update('setting_noindex' => '1')).to be true
      expect(settings.update('setting_boost_modal' => '0')).to be false
    end

    it 'does not delete a stored row when the submitted value is nil' do
      user.settings['default_sensitive'] = true

      settings.update('setting_default_sensitive' => nil)

      expect(user.settings['default_sensitive']).to be true
      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: 'default_sensitive')).to exist
    end

    it 'refuses false and an empty privacy string before saving' do
      expect do
        settings.update(
          'setting_default_sensitive' => false,
          'setting_default_privacy' => ''
        )
      end.to raise_error(UserSettingsDecorator::MissingLegacyWriter)

      expect(Setting.unscoped.where(thing_type: 'User', thing_id: user.id, var: %w(default_sensitive default_privacy))).to be_empty
    end

    it 'decoerces setting values before applying' do
      values = {
        'setting_delete_modal' => 'false',
        'setting_boost_modal' => 'true',
      }

      settings.update(values)
      expect(user.settings['delete_modal']).to eq false
      expect(user.settings['boost_modal']).to eq true
    end
  end

  describe 'update with a legacy writer' do
    self.use_transactional_tests = false

    let(:user) { Fabricate(:user) }

    after do
      next unless user&.id

      Setting.unscoped.where(thing_type: 'User', thing_id: user.id).delete_all
      UserPreferenceRevision.where(user_id: user.id).delete_all
      Account.where(id: user.account_id).delete_all
      User.where(id: user.id).delete_all
    end

    it 'saves nine keys in string then boolean order and advances revision' do
      writer = UserPreferences::LegacyWriter.new(user)
      seen = []
      allow(writer).to receive(:update).and_wrap_original do |method, key, value|
        seen << key
        method.call(key, value)
      end

      described_class.new(user, legacy_writer: writer).update(
        'setting_default_privacy' => 'unlisted',
        'setting_default_language' => 'de',
        'setting_default_sensitive' => '1',
        'setting_reduce_motion' => '0',
        'setting_boost_modal' => '1'
      )

      expect(seen).to eq %w(default_privacy default_language default_sensitive reduce_motion)
      expect(user.settings['default_privacy']).to eq 'unlisted'
      expect(user.settings['default_sensitive']).to be true
      expect(user.settings['reduce_motion']).to be false
      expect(user.settings['boost_modal']).to be true
      expect(UserPreferences::Revision.current(user.id)).to eq 4
    end
  end
end
