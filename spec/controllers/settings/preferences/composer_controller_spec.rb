# frozen_string_literal: true

require 'rails_helper'

describe Settings::Preferences::ComposerController do
  render_views

  let(:user) { Fabricate(:user) }

  before do
    sign_in user, scope: :user
  end

  describe 'GET #show' do
    it 'renders the default order and a navigation link' do
      get :show

      expect(response).to have_http_status(200)
      expect(response.body).to include(I18n.t('composer_toolbar.title'))
      expect(response.body).to include('name="user[composer_toolbar]"')
      expect(response.body).to include(ComposerToolbarPreference.dump(ComposerToolbarPreference.default_items))
      ComposerToolbarPreference::IDS.each do |id|
        expect(response.body).to include(I18n.t("composer_toolbar.items.#{id}"))
      end
      expect(response.body).to include(settings_preferences_composer_path)
      expect(response.body).to include('data-composer-toolbar-editor').and include('data-initial=')
      labels = JSON.parse(CGI.unescapeHTML(response.body[/data-labels="([^"]*)"/, 1]))
      expect(labels.dig('items', 'media')).to eq I18n.t('composer_toolbar.items.media')
      expect(labels.dig('placements', 'hidden')).to eq I18n.t('composer_toolbar.placements.hidden')
    end

    it 'renders a safe default when the stored value is corrupt' do
      user.settings['composer_toolbar'] = 'not-a-layout'

      get :show

      expect(response).to have_http_status(200)
      expect(response.body).to include(ComposerToolbarPreference.dump(ComposerToolbarPreference.default_items))
    end
  end

  describe 'PUT #update' do
    let(:reordered) do
      ComposerToolbarPreference.dump([
                                       { 'id' => 'poll', 'placement' => 'visible' },
                                       { 'id' => 'searchability', 'placement' => 'visible' },
                                       { 'id' => 'datetime', 'placement' => 'visible' },
                                       { 'id' => 'language', 'placement' => 'menu' },
                                       { 'id' => 'cw', 'placement' => 'menu' },
                                       { 'id' => 'media', 'placement' => 'menu' },
                                       { 'id' => 'posting_account', 'placement' => 'hidden' },
                                     ])
    end

    it 'persists a valid layout for this user only' do
      other = Fabricate(:user)

      put :update, params: { user: { composer_toolbar: reordered } }

      expect(response).to redirect_to(settings_preferences_composer_path)
      expect(user.reload.settings['composer_toolbar']).to eq reordered
      expect(other.reload.settings['composer_toolbar']).to be_nil
    end

    it 'does not store an invalid layout' do
      user.settings['composer_toolbar'] = ComposerToolbarPreference.dump(ComposerToolbarPreference.default_items)

      put :update, params: { user: { composer_toolbar: '{"items":"all"}' } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(user.reload.settings['composer_toolbar']).to eq ComposerToolbarPreference.dump(ComposerToolbarPreference.default_items)
      expect(response.body).to include(I18n.t('preferences.invalid_input', key: I18n.t('composer_toolbar.title')))
    end
  end
end
