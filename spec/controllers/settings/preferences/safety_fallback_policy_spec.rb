# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Settings::Preferences::SafetyController, type: :controller do
  render_views

  let(:user) { Fabricate(:user, locale: 'en') }

  around do |example|
    layout = described_class._layout
    described_class.layout false
    example.run
  ensure
    described_class.layout layout
  end

  before { sign_in user, scope: :user }

  it 'keeps emoji reaction preferences on the dedicated emoji settings page' do
    get :show

    expect(response).to have_http_status(200)
    expect(response.body).not_to include('user_setting_disable_reactions')
    expect(response.body).not_to include('user_setting_emoji_reaction_fallback_policy')
    expect(response.body).to include('user_setting_disable_follow')
  end
end
