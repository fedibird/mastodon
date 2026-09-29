# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InitialStateSerializer do
  def serialize(current_account)
    JSON.parse(
      ActiveModelSerializers::SerializableResource.new(
        InitialStatePresenter.new(current_account: current_account),
        serializer: described_class
      ).to_json,
      symbolize_names: true
    )
  end

  it 'includes language display names for the WebUI' do
    json = serialize(Fabricate(:user).account)
    english = json[:languages].find { |language| language[0] == 'en' }
    japanese = json[:languages].find { |language| language[0] == 'ja' }

    expect(english).to eq %w(en English English)
    expect(japanese).to eq %w(ja Japanese 日本語)
  end

  it 'uses the preferred posting language as the compose default' do
    user = Fabricate(:user, locale: 'en')
    user.settings[:default_language] = 'ja'
    json = serialize(user.account)

    expect(json[:compose][:default_language]).to eq user.preferred_posting_language
    expect(json[:compose][:default_language]).to eq 'ja'
  end

  it 'returns the Everyone role and keeps an invite-only user off the staff flag' do
    UserRole.everyone.update!(permissions: UserRole::FLAGS[:invite_users])
    user = Fabricate(:user)
    json = serialize(user.account)

    expect(json[:role][:id]).to eq '-99'
    expect(json[:role][:name]).to eq ''
    expect(json[:role][:permissions]).to eq UserRole::FLAGS[:invite_users].to_s
    expect(json[:meta][:is_staff]).to be false
  end

  it 'returns a custom role and marks manage_reports as staff' do
    role = UserRole.create!(name: 'Reporter', position: 4, permissions_as_keys: %w(manage_reports), color: '#abcdef', highlighted: true)
    user = user_with_role(role)
    json = serialize(user.account)

    expect(json[:role][:id]).to eq role.id.to_s
    expect(json[:role][:name]).to eq 'Reporter'
    expect(json[:role][:permissions]).to eq user.role.computed_permissions.to_s
    expect(json[:role][:color]).to eq '#abcdef'
    expect(json[:role][:highlighted]).to be true
    expect(json[:meta][:is_staff]).to be true
  end

  it 'returns the Owner role when role_id is Owner' do
    user = user_with_role('Owner')
    json = serialize(user.account)

    expect(json[:role][:name]).to eq 'Owner'
    expect(json[:role][:permissions]).to eq UserRole::Flags::ALL.to_s
    expect(json[:meta][:is_staff]).to be true
  end

  it 'does not raise when there is no current account' do
    json = nil

    expect { json = serialize(nil) }.not_to raise_error
    expect(json[:role]).to be_nil
    expect(json[:meta]).not_to have_key(:is_staff)
  end

  it 'exposes the status page URL without a current account' do
    previous = Setting.status_page_url
    Setting.status_page_url = 'https://status.example.com'

    json = serialize(nil)

    expect(json[:meta][:status_page_url]).to eq 'https://status.example.com'
  ensure
    Setting.status_page_url = previous
  end

  it 'exposes the server trends capability while retaining the legacy key' do
    previous_trends_setting = Setting.trends
    Setting.trends = true

    json = serialize(nil)

    expect(json[:meta][:trends_enabled]).to be true
    expect(json[:meta][:trends]).to be true
    expect(json[:meta]).not_to have_key(:show_trends)
  ensure
    Setting.trends = previous_trends_setting
  end

  it 'exposes private translation only for a signed-in session whose selected provider allows it' do
    user = Fabricate(:user)
    clear_provider = {
      DEEPL_API_KEY: nil,
      DEEPL_PLAN: nil,
      LIBRE_TRANSLATE_ENDPOINT: nil,
      LIBRE_TRANSLATE_API_KEY: nil,
      LIBRE_TRANSLATE_ALLOW_PRIVATE: nil,
    }

    ClimateControl.modify(clear_provider) do
      expect(serialize(user.account)[:meta][:translation_private_content_allowed]).to be false
      expect(serialize(nil)[:meta]).not_to have_key(:translation_private_content_allowed)
    end

    ClimateControl.modify(clear_provider.merge(LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true')) do
      expect(serialize(user.account)[:meta][:translation_private_content_allowed]).to be true
      expect(serialize(nil)[:meta]).not_to have_key(:translation_private_content_allowed)
    end

    ClimateControl.modify(clear_provider.merge(DEEPL_API_KEY: 'deepl-secret', LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true')) do
      expect(TranslationService.configured).to be_a(TranslationService::DeepL)
      expect(serialize(user.account)[:meta][:translation_private_content_allowed]).to be false
    end
  end

  it 'uses the viewer provider for private translation and omits it for anonymous sessions' do
    user = Fabricate(:user)
    other = Fabricate(:user)
    clear_provider = {
      DEEPL_API_KEY: nil,
      DEEPL_PLAN: nil,
      LIBRE_TRANSLATE_ENDPOINT: nil,
      LIBRE_TRANSLATE_API_KEY: nil,
      LIBRE_TRANSLATE_ALLOW_PRIVATE: nil,
    }

    with_vault_keyring do
      store_vault_credential(owner: user, secret: 'm2-initial-state-key')

      ClimateControl.modify(clear_provider.merge(LIBRE_TRANSLATE_ENDPOINT: 'http://127.0.0.1:5000', LIBRE_TRANSLATE_ALLOW_PRIVATE: 'true')) do
        signed_in = serialize(user.account)
        other_session = serialize(other.account)
        anonymous = serialize(nil)

        expect(signed_in[:meta][:translation_private_content_allowed]).to be false
        expect(other_session[:meta][:translation_private_content_allowed]).to be true
        expect(anonymous[:meta]).not_to have_key(:translation_private_content_allowed)
        expect(anonymous.to_json).not_to include('m2-initial-state-key')
        expect(signed_in.to_json).not_to include('m2-initial-state-key')
      end
    end
  end

  it 'derives translation bar visibility from the new-feature policy only while unset' do
    user = Fabricate(:user)

    expect(user.settings.show_translation_bar).to be_nil
    expect(user.setting_new_features_policy).to eq 'default'
    expect(user.setting_show_translation_bar).to eq 'target'
    expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'target'
    expect(serialize(user.account)[:meta]).not_to have_key(:show_translation_bar)

    user.settings.new_features_policy = 'tester'
    user.save!
    expect(user.settings.show_translation_bar).to be_nil
    expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'always'

    user.settings.new_features_policy = 'conservative'
    user.save!
    expect(user.settings.show_translation_bar).to be_nil
    expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'never'
    expect(serialize(nil)[:meta]).not_to have_key(:translation_bar_visibility)
    expect(serialize(nil)[:meta]).not_to have_key(:show_translation_bar)
  end

  it 'keeps an explicit translation bar choice ahead of a later policy change' do
    user = Fabricate(:user)

    user.settings.show_translation_bar = true
    user.settings.new_features_policy = 'conservative'
    user.save!
    expect(user.settings.show_translation_bar).to be true
    expect(user.setting_show_translation_bar).to eq 'always'
    expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'always'

    user.settings.show_translation_bar = false
    user.settings.new_features_policy = 'tester'
    user.save!
    expect(user.settings.show_translation_bar).to be false
    expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'never'

    user.settings.show_translation_bar = 'target'
    user.settings.new_features_policy = 'conservative'
    user.save!
    expect(user.settings.show_translation_bar).to eq 'target'
    expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'target'
  end

  it 'does not send an unknown translation bar visibility to the WebUI' do
    user = Fabricate(:user)
    user.settings.show_translation_bar = 'nope'
    user.settings.new_features_policy = 'default'
    user.save!

    expect(user.settings.show_translation_bar).to eq 'nope'
    expect(user.setting_show_translation_bar).to eq 'target'
    expect(serialize(user.account)[:meta][:translation_bar_visibility]).to eq 'target'
  end

  it 'exposes the translation display preference and defaults to translated' do
    user = Fabricate(:user)
    json = serialize(user.account)

    expect(user.setting_translation_preferred_mode).to eq 'translated'
    expect(json[:meta][:translation_preferred_mode]).to eq 'translated'

    user.settings.translation_preferred_mode = 'bilingual'
    user.save!
    expect(serialize(user.account)[:meta][:translation_preferred_mode]).to eq 'bilingual'

    user.settings.translation_preferred_mode = 'both'
    user.save!
    expect(user.setting_translation_preferred_mode).to eq 'both'
    expect(serialize(user.account)[:meta][:translation_preferred_mode]).to eq 'both'

    user.settings.translation_preferred_mode = 'nope'
    user.save!
    expect(user.setting_translation_preferred_mode).to eq 'translated'
    expect(serialize(user.account)[:meta][:translation_preferred_mode]).to eq 'translated'
  end

  it 'exposes the account trends preference under new and legacy keys' do
    previous_trends_setting = Setting.trends
    Setting.trends = true
    user = Fabricate(:user)

    json = serialize(user.account)

    expect(json[:meta][:trends_enabled]).to be true
    expect(json[:meta][:show_trends]).to eq user.setting_trends
    expect(json[:meta][:trends]).to eq json[:meta][:show_trends]
  ensure
    Setting.trends = previous_trends_setting
  end
end
