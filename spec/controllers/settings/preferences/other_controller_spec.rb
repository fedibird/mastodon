require 'rails_helper'

describe Settings::Preferences::OtherController do
  render_views

  let(:user) { Fabricate(:user, filtered_languages: []) }

  before do
    sign_in user, scope: :user
  end

  describe 'GET #show' do
    it 'returns http success without the moved emoji controls' do
      get :show
      expect(response).to have_http_status(200)
      expect(response.body).not_to include('user_setting_emoji_picker_disable_personal')
      expect(response.body).not_to include('user_setting_emoji_picker_disable_actions')
      expect(response.body).not_to include('user_setting_enable_reaction')
      expect(response.body).not_to include('user_setting_hide_reaction_counter')
      expect(response.body).not_to include('user_setting_hide_list_of_emoji_reactions_to_posts')
    end
  end

  describe 'PUT #update' do
    it 'updates the user record' do
      put :update, params: { user: { locale: 'en', chosen_languages: ['es', 'fr', ''] } }

      expect(response).to redirect_to(settings_preferences_other_path)
      user.reload
      expect(user.locale).to eq 'en'
      expect(user.chosen_languages).to eq ['es', 'fr']
    end

    it 'updates user settings' do
      user.settings['boost_modal'] = false
      user.settings['delete_modal'] = true

      put :update, params: {
        user: {
          setting_boost_modal: '1',
          setting_delete_modal: '0',
        }
      }

      expect(response).to redirect_to(settings_preferences_other_path)
      user.reload
      expect(user.settings['boost_modal']).to be true
      expect(user.settings['delete_modal']).to be false
    end
  end
end
