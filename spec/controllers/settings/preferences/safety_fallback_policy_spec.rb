# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::Preferences::SafetyController, type: :controller do
  render_views

  let(:user) { Fabricate(:user, locale: 'en') }

  # The admin layout pulls a webpack pack that this environment has not compiled.
  # The template itself is what the setting copy lives in.
  around do |example|
    layout = described_class._layout
    described_class.layout false
    example.run
  ensure
    described_class.layout layout
  end

  before { sign_in user, scope: :user }

  def stored
    Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'emoji_reaction_fallback_policy')
  end

  def html_copy(key)
    ERB::Util.html_escape(I18n.t(key, locale: :en))
  end

  it 'shows allow and deny, explains the scope, and says enforcement is off' do
    get :show

    expect(response).to have_http_status(200)
    expect(response.body).to include('user_setting_emoji_reaction_fallback_policy')
    expect(response.body).to include(html_copy('preferences.emoji_reaction_fallback_policy_scope'))
    expect(response.body).to include(html_copy('preferences.emoji_reaction_fallback_policy_not_enforced'))
    expect(response.body).to include(html_copy('preferences.emoji_reaction_fallback_policy_ask_unavailable'))
    expect(response.body).to include(html_copy('preferences.emoji_reaction_fallback_policy_disable_reactions'))
    expect(response.body).to include('value="allow"')
    expect(response.body).to include('value="deny"')
    expect(response.body).not_to include('value="ask"')
    expect(response.body).not_to include('no Like is ever')
    expect(response.body).not_to include('一切')
  end

  it 'says the server is applying the choice when enforcement is on' do
    ClimateControl.modify(
      'EMOJI_REACTION_CANONICAL_WRITES' => 'true',
      'EMOJI_REACTION_IDEMPOTENT_RETRY' => 'true',
      'EMOJI_REACTION_FALLBACK_POLICY_ENFORCE' => 'true'
    ) do
      get :show
    end

    expect(response.body).to include(html_copy('preferences.emoji_reaction_fallback_policy_enforced'))
    expect(response.body).not_to include(I18n.t('preferences.emoji_reaction_fallback_policy_not_enforced', locale: :en))
  end

  it 'saves deny and redisplays it' do
    put :update, params: { user: { setting_emoji_reaction_fallback_policy: 'deny' } }

    expect(response).to redirect_to(settings_preferences_safety_path)
    expect(stored.value).to eq 'deny'

    get :show
    expect(response.body).to match(/value="deny"[^>]*selected="selected"|selected="selected"[^>]*value="deny"/)
  end

  it 'rejects ask and any other value without saving, and does not save the rest of the form' do
    put :update, params: { user: { setting_emoji_reaction_fallback_policy: 'ask', setting_disable_post: '1' } }

    expect(response).to have_http_status(422)
    expect(stored).to be_nil
    expect(Setting.unscoped.find_by(thing_type: 'User', thing_id: user.id, var: 'disable_post')).to be_nil

    put :update, params: { user: { setting_emoji_reaction_fallback_policy: 'nope' } }
    expect(response).to have_http_status(422)
    expect(stored).to be_nil
  end

  it 'keeps a stored ask visible as a warning and will not overwrite it with a blank submit' do
    user.settings['emoji_reaction_fallback_policy'] = 'ask'
    get :show

    expect(response.body).to include(html_copy('preferences.emoji_reaction_fallback_policy_ask_stored'))
    expect(response.body).not_to include('value="ask"')

    put :update, params: { user: { setting_emoji_reaction_fallback_policy: '' } }
    expect(response).to have_http_status(422)
    expect(stored.value).to eq 'ask'
  end

  it 'saves ask when the picker confirmation is available' do
    allow(EmojiReactionCapability::FallbackPolicy).to receive(:picker_confirmation_available?).and_return(true)
    get :show
    expect(response.body).to include('value="ask"')

    put :update, params: { user: { setting_emoji_reaction_fallback_policy: 'ask' } }
    expect(response).to redirect_to(settings_preferences_safety_path)
    expect(stored.value).to eq 'ask'
  end
end
