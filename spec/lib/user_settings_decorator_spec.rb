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

    it 'updates the user settings value for privacy' do
      values = { 'setting_default_privacy' => 'public' }

      settings.update(values)
      expect(user.settings['default_privacy']).to eq 'public'
    end

    it 'updates the user settings value for sensitive' do
      values = { 'setting_default_sensitive' => '1' }

      settings.update(values)
      expect(user.settings['default_sensitive']).to eq true
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

    it 'saves translation bar visibility as a string without boolean casting' do
      user.settings.new_features_policy = 'conservative'
      user.save!

      settings.update({ 'setting_show_translation_bar' => 'always' })
      expect(user.settings.show_translation_bar).to eq 'always'
      expect(user.settings.show_translation_bar).to be_a(String)
      expect(user.setting_show_translation_bar).to eq 'always'

      settings.update({ 'setting_show_translation_bar' => 'target' })
      expect(user.settings.show_translation_bar).to eq 'target'
      expect(user.setting_show_translation_bar).to eq 'target'

      settings.update({ 'setting_show_translation_bar' => 'never' })
      expect(user.settings.show_translation_bar).to eq 'never'
      expect(user.setting_show_translation_bar).to eq 'never'

      settings.update({ 'setting_show_translation_bar' => '1' })
      expect(user.settings.show_translation_bar).to eq 'never'
      expect(user.settings.show_translation_bar).not_to be true
      expect(user.setting_show_translation_bar).to eq 'never'
    end

    it 'does not let a later policy change replace a saved translation bar choice' do
      settings.update({ 'setting_show_translation_bar' => 'target' })
      user.settings.new_features_policy = 'tester'
      user.save!

      expect(user.settings.show_translation_bar).to eq 'target'
      expect(user.setting_show_translation_bar).to eq 'target'
    end

    it 'normalizes an invalid translation bar visibility to the policy default' do
      user.settings.new_features_policy = 'tester'
      user.save!

      settings.update({ 'setting_show_translation_bar' => 'nope' })

      expect(user.settings.show_translation_bar).to eq 'always'
      expect(user.settings.show_translation_bar).to be_a(String)
      expect(user.setting_show_translation_bar).to eq 'always'
    end

    it 'accepts both as a pre-translation action and normalizes unknown modes' do
      settings.update({ 'setting_translation_preferred_mode' => 'both' })
      expect(user.settings.translation_preferred_mode).to eq 'both'
      expect(user.setting_translation_preferred_mode).to eq 'both'

      settings.update({ 'setting_translation_preferred_mode' => 'nope' })
      expect(user.settings.translation_preferred_mode).to eq 'translated'
      expect(user.setting_translation_preferred_mode).to eq 'translated'
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
end
